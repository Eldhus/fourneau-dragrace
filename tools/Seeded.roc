## Choices made from a seed, so a run replays: the order competitors race
## in each round, the order of a round's workloads, and the bytes of the
## request bodies. SplitMix64 (Steele, Lea and Flood, 2014), a generator
## whose whole state is one U64, and Fisher-Yates over it. Not Go's PCG: a
## seed replays in the tool that raced it.
Seeded :: [].{
	## A copy of `items` in the order the seed decides.
	shuffled : List(a), U64 -> List(a)
	shuffled = |items, seed| {
		var $order = items
		var $state = seed
		var $i = items.len()
		while $i > 1 {
			{ value, next } = Seeded.next($state)
			$state = next
			j = value % $i
			# Both indexes are below the length: the swap cannot fail.
			$order = $order.swap($i - 1, j) ?? $order
			$i = $i - 1
		}
		$order
	}

	## `count` bytes from the seed.
	bytes : U64, U64 -> List(U8)
	bytes = |seed, count| {
		var $out = List.with_capacity(count)
		var $state = seed
		while $out.len() < count {
			{ value, next } = Seeded.next($state)
			$state = next
			var $word = value
			var $k = 0
			while $k < 8 and $out.len() < count {
				$out = $out.append(($word % 256).to_u8_wrap())
				$word = $word // 256
				$k = $k + 1
			}
		}
		$out
	}

	## One step: a number and the state after it.
	next : U64 -> { value : U64, next : U64 }
	next = |state| {
		next = state.plus_wrap(0x9E3779B97F4A7C15)
		z1 = (next.bitwise_xor(next.shr_zf_wrap(30))).times_wrap(0xBF58476D1CE4E5B9)
		z2 = (z1.bitwise_xor(z1.shr_zf_wrap(27))).times_wrap(0x94D049BB133111EB)
		{ value: z2.bitwise_xor(z2.shr_zf_wrap(31)), next }
	}

	## FNV-1a of a string, 64 bits: a name's own part of a seed.
	fnv : Str -> U64
	fnv = |text|
		text.to_utf8().fold(0xcbf29ce484222325, |hash, byte| hash.bitwise_xor(byte.to_u64()).times_wrap(0x100000001b3))

	## A seed and a number mixed into another seed, for one choice of many.
	mix : U64, U64 -> U64
	mix = |seed, salt| (Seeded.next(seed.bitwise_xor(salt.times_wrap(0x9E3779B97F4A7C15)))).value
}

# SplitMix64's first output from seed 0, as its reference prints it.
expect Seeded.next(0).value == 0xE220A8397B1DCDAF

expect Seeded.fnv("") == 0xcbf29ce484222325
expect Seeded.fnv("a") == 0xaf63dc4c8601ec8c

expect {
	order = Seeded.shuffled([1, 2, 3, 4, 5, 6, 7], 42)
	order.len() == 7 and order.sort() == [1, 2, 3, 4, 5, 6, 7] and order == Seeded.shuffled([1, 2, 3, 4, 5, 6, 7], 42)
}

expect Seeded.shuffled([1, 2, 3, 4, 5, 6, 7], 1) != Seeded.shuffled([1, 2, 3, 4, 5, 6, 7], 2)
expect Seeded.bytes(7, 13).len() == 13
expect Seeded.bytes(7, 13) == Seeded.bytes(7, 13)
expect Seeded.bytes(7, 13) != Seeded.bytes(8, 13)
