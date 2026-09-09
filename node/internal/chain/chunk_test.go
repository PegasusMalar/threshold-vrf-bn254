package chain

import "testing"

// Providers cap how wide an eth_getLogs range may be, and the caps differ
// wildly: Alchemy's free tier allows ten blocks, others tens of thousands. A
// node that cannot split a range is tied to whichever endpoints happen to be
// permissive — which is the opposite of what per-operator RPCs are for.
func TestARangeIsSplitToFitTheProvidersCap(t *testing.T) {
	for _, tc := range []struct {
		name       string
		from, to   uint64
		max        uint64
		wantChunks [][2]uint64
	}{
		{"no cap means one call", 100, 5000, 0, [][2]uint64{{100, 5000}}},
		{"range under the cap is untouched", 100, 105, 10, [][2]uint64{{100, 105}}},
		{"exactly the cap is one call", 100, 109, 10, [][2]uint64{{100, 109}}},
		{"one over the cap splits", 100, 110, 10, [][2]uint64{{100, 109}, {110, 110}}},
		{"a wide range splits evenly", 0, 24, 10, [][2]uint64{{0, 9}, {10, 19}, {20, 24}}},
		{"a single block is one call", 42, 42, 10, [][2]uint64{{42, 42}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := chunkRange(tc.from, tc.to, tc.max)
			if len(got) != len(tc.wantChunks) {
				t.Fatalf("%d chunks, want %d: %v", len(got), len(tc.wantChunks), got)
			}
			for i := range got {
				if got[i] != tc.wantChunks[i] {
					t.Fatalf("chunk %d is %v, want %v", i, got[i], tc.wantChunks[i])
				}
			}
		})
	}
}

// Every block in the original range must appear in exactly one chunk: a gap
// loses requests silently, and an overlap makes a node sign the same seed twice.
func TestChunksCoverTheRangeExactlyOnce(t *testing.T) {
	const from, to, max = 1000, 1237, 10
	chunks := chunkRange(from, to, max)

	next := uint64(from)
	for _, c := range chunks {
		if c[0] != next {
			t.Fatalf("chunk starts at %d, expected %d — gap or overlap", c[0], next)
		}
		if c[1] < c[0] {
			t.Fatalf("chunk %v runs backwards", c)
		}
		if c[1]-c[0]+1 > max {
			t.Fatalf("chunk %v is wider than the cap of %d", c, max)
		}
		next = c[1] + 1
	}
	if next != to+1 {
		t.Fatalf("coverage ends at %d, expected %d", next-1, to)
	}
}
