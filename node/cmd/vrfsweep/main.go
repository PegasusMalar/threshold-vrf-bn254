// Command vrfsweep empties one operator's publishing account and sends the
// proceeds to a single destination.
//
// It exists because of where the keys are. Every operator's Ethereum key was
// generated on its own server and has only ever lived there: deploy-node.sh
// goes out of its way never to let one pass through the machine that runs the
// deploy. Winding the fleet down must not be the moment that property is
// broken, so the sweep runs where the key already is, and the key never moves.
//
// Two steps, in this order, because the first one costs gas that the second
// one would otherwise take away:
//
//	1. withdraw(to)  — fees the operator earned, still sitting in Subscription
//	2. a plain transfer of whatever native balance is left, minus its own fee
//
// Both are skipped when there is nothing to move, so running it twice is safe
// and the second run is a no-op rather than a failed transaction.
package main

import (
	"context"
	"crypto/ecdsa"
	"flag"
	"fmt"
	"log"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

// The two selectors this needs, computed rather than pasted so a typo cannot
// silently call something else.
func selector(sig string) []byte { return crypto.Keccak256([]byte(sig))[:4] }

func main() {
	rpc := flag.String("rpc", "", "RPC endpoint")
	subs := flag.String("subscription", "", "Subscription contract holding the earned fees")
	to := flag.String("to", "", "destination for everything")
	dry := flag.Bool("dry", false, "report what would move and send nothing")
	flag.Parse()

	if *rpc == "" || *to == "" {
		log.Fatal("need -rpc and -to")
	}
	// Checksum is the only defence against a mistyped destination, and a
	// mistyped destination here is unrecoverable.
	if !common.IsHexAddress(*to) {
		log.Fatalf("destination %q is not an address", *to)
	}
	dest := common.HexToAddress(*to)
	if dest.Hex() != *to {
		log.Fatalf("destination fails its EIP-55 checksum: given %s, checksummed %s", *to, dest.Hex())
	}

	raw := strings.TrimSpace(os.Getenv("VRF_ETH_PRIVATE_KEY"))
	if raw == "" {
		log.Fatal("VRF_ETH_PRIVATE_KEY is not set")
	}
	key, err := crypto.HexToECDSA(strings.TrimPrefix(raw, "0x"))
	if err != nil {
		log.Fatalf("private key: %v", err)
	}
	from := crypto.PubkeyToAddress(*key.Public().(*ecdsa.PublicKey))

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	client, err := ethclient.DialContext(ctx, *rpc)
	if err != nil {
		log.Fatalf("dial: %v", err)
	}
	defer client.Close()

	chainID, err := client.ChainID(ctx)
	if err != nil {
		log.Fatalf("chain id: %v", err)
	}
	gasPrice, err := client.SuggestGasPrice(ctx)
	if err != nil {
		log.Fatalf("gas price: %v", err)
	}
	// The suggestion is a snapshot of a base fee that keeps moving, and this
	// chain produces blocks fast enough that it has already moved by the time
	// the transaction arrives: five of the first nine sweeps were rejected with
	// "max fee per gas less than block base fee" over a difference of less than
	// one percent. Overpay deliberately. At 21000 gas the whole margin is worth
	// a hundredth of a cent, and a rejected sweep costs another round trip to a
	// server that is about to be deleted.
	gasPrice = new(big.Int).Mul(gasPrice, big.NewInt(3))

	fmt.Printf("from      %s\n", from.Hex())
	fmt.Printf("to        %s\n", dest.Hex())
	fmt.Printf("chain     %s   gas price %s wei\n", chainID, gasPrice)

	send := func(what string, target common.Address, value *big.Int, data []byte, gas uint64) {
		if *dry {
			fmt.Printf("  would send %s\n", what)
			return
		}
		nonce, err := client.PendingNonceAt(ctx, from)
		if err != nil {
			log.Fatalf("%s: nonce: %v", what, err)
		}
		tx := types.NewTx(&types.LegacyTx{
			Nonce: nonce, To: &target, Value: value, Gas: gas, GasPrice: gasPrice, Data: data,
		})
		signed, err := types.SignTx(tx, types.LatestSignerForChainID(chainID), key)
		if err != nil {
			log.Fatalf("%s: sign: %v", what, err)
		}
		if err := client.SendTransaction(ctx, signed); err != nil {
			log.Fatalf("%s: send: %v", what, err)
		}
		fmt.Printf("  %s -> %s\n", what, signed.Hash().Hex())
		for {
			r, err := client.TransactionReceipt(ctx, signed.Hash())
			if err == nil {
				fmt.Printf("  status %d, gas used %d\n", r.Status, r.GasUsed)
				if r.Status != 1 {
					log.Fatalf("%s reverted", what)
				}
				return
			}
			select {
			case <-ctx.Done():
				log.Fatalf("%s: receipt: %v", what, ctx.Err())
			case <-time.After(500 * time.Millisecond):
			}
		}
	}

	// Step one: the fees. Nothing here is ours to leave behind, but a withdraw
	// of zero is a wasted fee, so ask first.
	if *subs != "" {
		sub := common.HexToAddress(*subs)
		arg := common.LeftPadBytes(from.Bytes(), 32)
		out, err := client.CallContract(ctx, ethereum.CallMsg{
			To: &sub, Data: append(selector("withdrawableOf(address)"), arg...),
		}, nil)
		if err != nil {
			log.Fatalf("withdrawableOf: %v", err)
		}
		earned := new(big.Int).SetBytes(out)
		fmt.Printf("earned    %s wei\n", earned)
		if earned.Sign() > 0 {
			data := append(selector("withdraw(address)"), common.LeftPadBytes(dest.Bytes(), 32)...)
			gas, err := client.EstimateGas(ctx, ethereum.CallMsg{From: from, To: &sub, Data: data})
			if err != nil {
				log.Fatalf("estimate withdraw: %v", err)
			}
			send("withdraw", sub, big.NewInt(0), data, gas+gas/4)
		}
	}

	// Step two: whatever is left, minus exactly what moving it costs. A plain
	// transfer to an account is 21000 and cannot be anything else.
	balance, err := client.BalanceAt(ctx, from, nil)
	if err != nil {
		log.Fatalf("balance: %v", err)
	}
	fee := new(big.Int).Mul(big.NewInt(21000), gasPrice)
	value := new(big.Int).Sub(balance, fee)
	fmt.Printf("balance   %s wei, fee %s wei\n", balance, fee)
	if value.Sign() <= 0 {
		fmt.Println("  nothing left worth moving")
		return
	}
	send(fmt.Sprintf("sweep %s wei", value), dest, value, nil, 21000)
}
