(* Test the 4 step algorithm twiddle calculation logic. *)

open Base
open Hardcaml
open! Hardcaml_waveterm
open Expect_test_helpers_base
module Gf = Hardcaml_ntt.Gf.Z
module Ntt = Hardcaml_ntt.Reference_model.Make (Gf)

let logn = 3
let n = 1 lsl logn

let%expect_test "show twiddle generation" =
  let a = Array.init n ~f:(fun _ -> Array.init n ~f:(fun _ -> Gf.one)) in
  Ntt.apply_twiddles Ntt.inverse_roots.(n) a;
  print_s [%message (a : Gf.t array array)];
  [%expect
    {|
    (a (
      (1 1 1 1 1 1 1 1)
      (1
       13797081185216407910
       17870292113338400769
       281721071064741919
       549755813888
       14041890976876060974
       1125917086449664
       4299803665592489687)
      (1
       17870292113338400769
       549755813888
       1125917086449664
       70368744161280
       2198989700608
       18446744069412487169
       18446744065119551490)
      (1
       281721071064741919
       1125917086449664
       3051558327610197629
       18446744069412487169
       411429644661718300
       18410715272395620481
       18142929134658341675)
      (1
       549755813888
       70368744161280
       18446744069412487169
       17293822564807737345
       8
       4398046511104
       562949953290240)
      (1
       14041890976876060974
       2198989700608
       411429644661718300
       8
       1654663398520981866
       17591917604864
       3291437157293746400)
      (1
       1125917086449664
       18446744069412487169
       18410715272395620481
       4398046511104
       17591917604864
       9223372032559808513
       562949953421314)
      (1
       4299803665592489687
       18446744065119551490
       18142929134658341675
       562949953290240
       3291437157293746400
       562949953421314
       10832292272906805046))) |}];
  (* Iteratively generate the twiddles in batches. This is needed to hide the
     latency of the multiplier.

     So far we can hide it within rows, though I haven't yet worked out how to
     hide it as we go to the next set of rows (although I think I see how it's
     done, and it will require a few extra cycles to calculate).
  *)
  let root = Ntt.inverse_roots.(n) in
  let r4 = Gf.pow root 4 in
  let initial_roots row = Array.init 4 ~f:(fun col -> Gf.pow root (row * col)) in
  let twiddle_row row =
    let initial = initial_roots row in
    let step = Gf.pow root (row * 4) in
    let next = Array.map initial ~f:(Gf.( * ) step) in
    print_s [%message (initial : Gf.t array) (next : Gf.t array)]
  in
  print_s [%message (root : Gf.t) (r4 : Gf.t)];
  twiddle_row 0;
  twiddle_row 1;
  twiddle_row 4;
  twiddle_row 5;
  [%expect
    {|
    ((root 13797081185216407910)
     (r4   549755813888))
    ((initial (1 1 1 1))
     (next    (1 1 1 1)))
    ((initial (1 13797081185216407910 17870292113338400769 281721071064741919))
     (next (
       549755813888 14041890976876060974 1125917086449664 4299803665592489687)))
    ((initial (1 549755813888 70368744161280 18446744069412487169))
     (next (17293822564807737345 8 4398046511104 562949953290240)))
    ((initial (1 14041890976876060974 2198989700608 411429644661718300))
     (next (8 1654663398520981866 17591917604864 3291437157293746400))) |}];
  let i0 = initial_roots 0 in
  let i1 = initial_roots 1 in
  let i4 = Array.map i0 ~f:(Gf.( * ) r4) in
  let i5 = Array.map i1 ~f:(Gf.( * ) r4) in
  print_s [%message (i4 : Gf.t array) (i5 : Gf.t array)];
  [%expect
    {|
    ((i4 (549755813888 549755813888 549755813888 549755813888))
     (i5 (549755813888 14041890976876060974 1125917086449664 4299803665592489687))) |}]
;;

let%expect_test "" =
  let module Gf_bits = Hardcaml_ntt.Gf.Bits in
  let module Sim =
    Cyclesim.With_interface
      (Hardcaml_ntt.Twiddle_factor_stream.I)
      (Hardcaml_ntt.Twiddle_factor_stream.O)
  in
  let sim = Sim.create (Hardcaml_ntt.Twiddle_factor_stream.create (Scope.create ())) in
  let waves, sim = Waveform.create sim in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let pow p = Gf.pow Ntt.inverse_roots.(n) p in
  let twiddle_factor_stream_pipe_length = List.length inputs.omegas in
  let row r =
    List.iteri inputs.omegas ~f:(fun i ref_omega ->
      ref_omega := r.(i) |> Gf.to_z |> Gf_bits.of_z |> Gf_bits.to_bits);
    inputs.start_twiddles := Bits.vdd;
    let results = ref [] in
    for _ = 0 to n - 1 do
      Cyclesim.cycle sim;
      inputs.start_twiddles := Bits.gnd;
      results := Gf_bits.of_bits !(outputs.w) :: !results
    done;
    List.rev !results
  in
  let omegas =
    Array.init twiddle_factor_stream_pipe_length ~f:(fun r ->
      Array.init twiddle_factor_stream_pipe_length ~f:(fun c -> pow (r * (c + 1))))
  in
  let scale =
    Array.init twiddle_factor_stream_pipe_length ~f:(fun i ->
      pow ((i + 1) * twiddle_factor_stream_pipe_length))
  in
  for _ = 0 to 1 do
    print_s [%message (omegas : Gf.t array array)];
    for r = 0 to twiddle_factor_stream_pipe_length - 1 do
      let results = row omegas.(r) in
      print_s [%message "" ~_:(results : Gf_bits.t list)]
    done;
    for i = 0 to twiddle_factor_stream_pipe_length - 1 do
      for j = 0 to twiddle_factor_stream_pipe_length - 1 do
        omegas.(i).(j) <- Gf.( * ) omegas.(i).(j) scale.(j)
      done
    done
  done;
  Waveform.print waves ~display_height:25 ~display_width:90 ~wave_width:1;
  [%expect
    {|
    (omegas (
      (1 1 1 1 1 1 1)
      (13797081185216407910
       17870292113338400769
       281721071064741919
       549755813888
       14041890976876060974
       1125917086449664
       4299803665592489687)
      (17870292113338400769
       549755813888
       1125917086449664
       70368744161280
       2198989700608
       18446744069412487169
       18446744065119551490)
      (281721071064741919
       1125917086449664
       3051558327610197629
       18446744069412487169
       411429644661718300
       18410715272395620481
       18142929134658341675)
      (549755813888
       70368744161280
       18446744069412487169
       17293822564807737345
       8
       4398046511104
       562949953290240)
      (14041890976876060974
       2198989700608
       411429644661718300
       8
       1654663398520981866
       17591917604864
       3291437157293746400)
      (1125917086449664
       18446744069412487169
       18410715272395620481
       4398046511104
       17591917604864
       9223372032559808513
       562949953421314)))
    (1 1 1 1 1 1 1 1)
    (1
     13797081185216407910
     17870292113338400769
     281721071064741919
     549755813888
     14041890976876060974
     1125917086449664
     4299803665592489687)
    (1
     17870292113338400769
     549755813888
     1125917086449664
     70368744161280
     2198989700608
     18446744069412487169
     18446744065119551490)
    (1
     281721071064741919
     1125917086449664
     3051558327610197629
     18446744069412487169
     411429644661718300
     18410715272395620481
     18142929134658341675)
    (1
     549755813888
     70368744161280
     18446744069412487169
     17293822564807737345
     8
     4398046511104
     562949953290240)
    (1
     14041890976876060974
     2198989700608
     411429644661718300
     8
     1654663398520981866
     17591917604864
     3291437157293746400)
    (1
     1125917086449664
     18446744069412487169
     18410715272395620481
     4398046511104
     17591917604864
     9223372032559808513
     562949953421314)
    (omegas (
      (4299803665592489687
       18446744065119551490
       18142929134658341675
       562949953290240
       3291437157293746400
       562949953421314
       10832292272906805046)
      (70368744161280
       17293822564807737345
       4398046511104
       18446744069397807105
       64
       4503599626321920
       18446744052234715141)
      (3051558327610197629
       18410715272395620481
       15951685255325333175
       9223372032559808513
       13237307188167854928
       18446743794532483137
       15113979899245772281)
      (2198989700608 8 17591917604864 64 140735340838912 512 1125882726711296)
      (11387280211730213981
       13835128420805115905
       14004640413449681173
       35184372088832
       7884753188935386879
       576469548262227968
       4497639551463306333)
      (18446744069412487169
       4398046511104
       9223372032559808513
       4503599626321920
       512
       18446744068340842497
       2251799813685248)
      (8668109077711679267
       9007336691597312
       6393075107303762937
       18446744069280366593
       13664737158269917819
       18446744065119682562
       8930739766887302688)))
    (1
     4299803665592489687
     18446744065119551490
     18142929134658341675
     562949953290240
     3291437157293746400
     562949953421314
     10832292272906805046)
    (1
     70368744161280
     17293822564807737345
     4398046511104
     18446744069397807105
     64
     4503599626321920
     18446744052234715141)
    (1
     3051558327610197629
     18410715272395620481
     15951685255325333175
     9223372032559808513
     13237307188167854928
     18446743794532483137
     15113979899245772281)
    (1 2198989700608 8 17591917604864 64 140735340838912 512 1125882726711296)
    (1
     11387280211730213981
     13835128420805115905
     14004640413449681173
     35184372088832
     7884753188935386879
     576469548262227968
     4497639551463306333)
    (1
     18446744069412487169
     4398046511104
     9223372032559808513
     4503599626321920
     512
     18446744068340842497
     2251799813685248)
    (1
     8668109077711679267
     9007336691597312
     6393075107303762937
     18446744069280366593
     13664737158269917819
     18446744065119682562
     8930739766887302688)
    ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────────────┐
    │clock             ││┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ │
    │                  ││  └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─│
    │                  ││────────────────────────────────┬───────────────────────────────┬───│
    │omegas0           ││ 0000000000000001               │BF79143CE60CA966               │F8.│
    │                  ││────────────────────────────────┴───────────────────────────────┴───│
    │                  ││────────────────────────────────┬───────────────────────────────┬───│
    │omegas1           ││ 0000000000000001               │F80007FF08000001               │00.│
    │                  ││────────────────────────────────┴───────────────────────────────┴───│
    │                  ││────────────────────────────────┬───────────────────────────────┬───│
    │omegas2           ││ 0000000000000001               │03E8DFD24E8E781F               │00.│
    │                  ││────────────────────────────────┴───────────────────────────────┴───│
    │                  ││────────────────────────────────┬───────────────────────────────┬───│
    │omegas3           ││ 0000000000000001               │0000008000000000               │00.│
    │                  ││────────────────────────────────┴───────────────────────────────┴───│
    │                  ││────────────────────────────────┬───────────────────────────────┬───│
    │omegas4           ││ 0000000000000001               │C2DED1724375E12E               │00.│
    │                  ││────────────────────────────────┴───────────────────────────────┴───│
    │                  ││────────────────────────────────┬───────────────────────────────┬───│
    │omegas5           ││ 0000000000000001               │00040003FFFC0000               │FF.│
    │                  ││────────────────────────────────┴───────────────────────────────┴───│
    │                  ││────────────────────────────────┬───────────────────────────────┬───│
    │omegas6           ││ 0000000000000001               │3BABF8A70B9016D7               │FF.│
    │                  ││────────────────────────────────┴───────────────────────────────┴───│
    └──────────────────┘└────────────────────────────────────────────────────────────────────┘ |}]
;;
