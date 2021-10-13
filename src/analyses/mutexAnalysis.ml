(** Mutex analysis. *)

module M = Messages
module GU = Goblintutil
module Addr = ValueDomain.Addr
module Offs = ValueDomain.Offs
module Lockset = LockDomain.Lockset
module Mutexes = LockDomain.Mutexes
module AD = ValueDomain.AD
module ID = ValueDomain.ID
module IdxDom = ValueDomain.IndexDomain
module LockingPattern = Exp.LockingPattern
module Exp = Exp.Exp
(*module BS = Base.Spec*)
module LF = LibraryFunctions
open Prelude.Ana
open Analyses
open GobConfig

let big_kernel_lock = LockDomain.Addr.from_var (Goblintutil.create_var (makeGlobalVar "[big kernel lock]" intType))
let console_sem = LockDomain.Addr.from_var (Goblintutil.create_var (makeGlobalVar "[console semaphore]" intType))
let verifier_atomic = LockDomain.Addr.from_var (Goblintutil.create_var (makeGlobalVar "[__VERIFIER_atomic]" intType))

module type SpecParam =
sig
  module G: Lattice.S
  val effect_fun: ?write:bool -> Lockset.t -> G.t
  val check_fun: ?write:bool -> Lockset.t -> G.t
end

(** Mutex analyzer without base --- this is the new standard *)
module MakeSpec (P: SpecParam) =
struct
  include Analyses.DefaultSpec

  (** name for the analysis (btw, it's "Only Mutex Must") *)
  let name () = "mutex"

  (** Add current lockset alongside to the base analysis domain. Global data is collected using dirty side-effecting. *)
  module D = Lockset
  module C = Lockset

  (** We do not add global state, so just lift from [BS]*)
  module G = P.G

  let should_join x y = D.equal x y

  (* NB! Currently we care only about concrete indexes. Base (seeing only a int domain
     element) answers with the string "unknown" on all non-concrete cases. *)
  let rec conv_offset x =
    match x with
    | `NoOffset    -> `NoOffset
    | `Index (Const (CInt64 (i,_,s)),o) -> `Index (IntDomain.of_const (i,Cilfacade.ptrdiff_ikind (),s), conv_offset o)
    | `Index (_,o) -> `Index (ValueDomain.IndexDomain.top (), conv_offset o)
    | `Field (f,o) -> `Field (f, conv_offset o)

  let rec conv_offset_inv = function
    | `NoOffset -> `NoOffset
    | `Field (f, o) -> `Field (f, conv_offset_inv o)
    (* TODO: better indices handling *)
    | `Index (_, o) -> `Index (MyCFG.unknown_exp, conv_offset_inv o)

  (* TODO: unused *)
  let rec conv_const_offset x =
    match x with
    | NoOffset    -> `NoOffset
    | Index (Const (CInt64 (i,_,s)),o) -> `Index (IntDomain.of_const (i,Cilfacade.ptrdiff_ikind (),s), conv_const_offset o)
    | Index (_,o) -> `Index (ValueDomain.IndexDomain.top (), conv_const_offset o)
    | Field (f,o) -> `Field (f, conv_const_offset o)

  (* TODO: unused *)
  let rec replace_elem (v,o) q ex =
    match ex with
    | AddrOf  (Mem e,_) when Basetype.CilExp.equal e q ->v, Offs.from_offset (conv_offset o)
    | StartOf (Mem e,_) when Basetype.CilExp.equal e q ->v, Offs.from_offset (conv_offset o)
    | Lval    (Mem e,_) when Basetype.CilExp.equal e q ->v, Offs.from_offset (conv_offset o)
    | CastE (_,e)           -> replace_elem (v,o) q e
    | _ -> v, Offs.from_offset (conv_offset o)

  let part_access ctx e v w =
    let open Access in
    let ps = LSSSet.singleton (LSSet.empty ()) in
    let add_lock l =
      let ls = Lockset.Lock.show l in
      LSSet.add ("lock",ls)
    in
    let locks =
      if w then
        (* when writing: ignore reader locks *)
        Lockset.filter snd ctx.local
      else
        (* when reading: bump reader locks to exclusive as they protect reads *)
        Lockset.map (fun (x,_) -> (x,true)) ctx.local
    in
    let ls = D.fold add_lock locks (LSSet.empty ()) in
    (ps, ls)

  let eval_exp_addr (a: Queries.ask) exp =
    let gather_addr (v,o) b = ValueDomain.Addr.from_var_offset (v,conv_offset o) :: b in
    match a.f (Queries.MayPointTo exp) with
    | a when not (Queries.LS.is_top a)
                   && not (Queries.LS.mem (dummyFunDec.svar,`NoOffset) a) ->
      Queries.LS.fold gather_addr (Queries.LS.remove (dummyFunDec.svar, `NoOffset) a) []
    | _ -> []

  let lock ctx rw may_fail nonzero_return_when_aquired a lv arglist ls =
    let is_a_blob addr =
      match LockDomain.Addr.to_var addr with
      | [a] -> a.vname.[0] = '('
      | _ -> false
    in
    let lock_one (e:LockDomain.Addr.t) =
      if is_a_blob e then
        ls
      else begin
        let nls = Lockset.add (e,rw) ls in
        match lv with
        | None ->
          if may_fail then
            ls
          else (
            ctx.emit (Events.Lock e);
            nls
          )
        | Some lv ->
          ctx.split nls [Events.SplitBranch (Lval lv, nonzero_return_when_aquired); Events.Lock e];
          if may_fail then (
            let fail_exp = if nonzero_return_when_aquired then Lval lv else BinOp(Gt, Lval lv, zero, intType) in
            ctx.split ls [Events.SplitBranch (fail_exp, not nonzero_return_when_aquired)]
          );
          raise Analyses.Deadcode
      end
    in
    match arglist with
    | [x] -> begin match  (eval_exp_addr a x) with
        | [e]  -> lock_one e
        | _ -> ls
      end
    | _ -> Lockset.top ()

  (* TODO: unused *)
  let arinc_analysis_activated = ref false


  (** We just lift start state, global and dependency functions: *)
  let startstate v = Lockset.empty ()
  let threadenter ctx lval f args = [Lockset.empty ()]
  let exitstate  v = Lockset.empty ()

  let query ctx (type a) (q: a Queries.t): a Queries.result =
    let non_overlapping locks1 locks2 =
      let intersect = G.join locks1 locks2 in
      G.is_top intersect
    in
    match q with
    | Queries.MayBePublic _ when Lockset.is_bot ctx.local -> false
    | Queries.MayBePublic {global=v; write} ->
      let held_locks: G.t = P.check_fun ~write (Lockset.filter snd ctx.local) in
      (* TODO: unsound in 29/24, why did we do this before? *)
      (* if Mutexes.mem verifier_atomic (Lockset.export_locks ctx.local) then
        false
      else *)
        non_overlapping held_locks (ctx.global v)
    | Queries.MayBePublicWithout _ when Lockset.is_bot ctx.local -> false
    | Queries.MayBePublicWithout {global=v; write; without_mutex} ->
      let held_locks: G.t = P.check_fun ~write (Lockset.remove (without_mutex, true) (Lockset.filter snd ctx.local)) in
      (* TODO: unsound in 29/24, why did we do this before? *)
      (* if Mutexes.mem verifier_atomic (Lockset.export_locks (Lockset.remove (without_mutex, true) ctx.local)) then
        false
      else *)
         non_overlapping held_locks (ctx.global v)
    | Queries.MustBeProtectedBy {mutex; global; write} ->
      let mutex_lockset = Lockset.singleton (mutex, true) in
      let held_locks: G.t = P.check_fun ~write mutex_lockset in
      (* TODO: unsound in 29/24, why did we do this before? *)
      (* if LockDomain.Addr.equal mutex verifier_atomic then
        true
      else *)
        G.leq (ctx.global global) held_locks
    | Queries.CurrentLockset ->
      let held_locks = Lockset.export_locks (Lockset.filter snd ctx.local) in
      let ls = Mutexes.fold (fun addr ls ->
          match Addr.to_var_offset addr with
          | [(var, offs)] -> Queries.LS.add (var, conv_offset_inv offs) ls
          | _ -> ls
        ) held_locks (Queries.LS.empty ())
      in
      ls
    | Queries.MustBeAtomic ->
      let held_locks = Lockset.export_locks (Lockset.filter snd ctx.local) in
      Mutexes.mem verifier_atomic held_locks
    | Queries.PartAccess {exp; var_opt; write} ->
      part_access ctx exp var_opt write
    | _ -> Queries.Result.top q


  (** Transfer functions: *)

  let assign ctx lval rval : D.t =
    ctx.local

  let branch ctx exp tv : D.t =
    ctx.local

  let return ctx exp fundec : D.t =
    (* deprecated but still valid SV-COMP convention for atomic block *)
    if get_bool "ana.sv-comp.functions" && String.starts_with fundec.svar.vname "__VERIFIER_atomic_" then (
      ctx.emit (Events.Unlock verifier_atomic);
      Lockset.remove (verifier_atomic, true) ctx.local
    )
    else
      ctx.local

  let body ctx f : D.t =
    (* deprecated but still valid SV-COMP convention for atomic block *)
    if get_bool "ana.sv-comp.functions" && String.starts_with f.svar.vname "__VERIFIER_atomic_" then (
      ctx.emit (Events.Lock verifier_atomic);
      Lockset.add (verifier_atomic, true) ctx.local
    )
    else
      ctx.local

  let special ctx lv f arglist : D.t =
    let remove_rw x st =
      ctx.emit (Events.Unlock x);
      Lockset.remove (x,true) (Lockset.remove (x,false) st)
    in
    let unlock remove_fn =
      let remove_nonspecial x =
        if Lockset.is_top x then x else
          Lockset.filter (fun (v,_) -> match LockDomain.Addr.to_var v with
              | [v] when v.vname.[0] = '{' -> true
              | _ -> false
            ) x
      in
      match arglist with
      | x::xs -> begin match  (eval_exp_addr (Analyses.ask_of_ctx ctx) x) with
          | [] -> remove_nonspecial ctx.local
          | es -> List.fold_right remove_fn es ctx.local
        end
      | _ -> ctx.local
    in
    match (LF.classify f.vname arglist, f.vname) with
    | _, "_lock_kernel" ->
      ctx.emit (Events.Lock big_kernel_lock);
      Lockset.add (big_kernel_lock,true) ctx.local
    | _, "_unlock_kernel" ->
      ctx.emit (Events.Unlock big_kernel_lock);
      Lockset.remove (big_kernel_lock,true) ctx.local
    | `Lock (failing, rw, nonzero_return_when_aquired), _
      -> let arglist = if f.vname = "LAP_Se_WaitSemaphore" then [List.hd arglist] else arglist in
      (*print_endline @@ "Mutex `Lock "^f.vname;*)
      lock ctx rw failing nonzero_return_when_aquired (Analyses.ask_of_ctx ctx) lv arglist ctx.local
    | `Unlock, "__raw_read_unlock"
    | `Unlock, "__raw_write_unlock"  ->
      let drop_raw_lock x =
        let rec drop_offs o =
          match o with
          | `Field ({fname="raw_lock"; _},`NoOffset) -> `NoOffset
          | `Field (f1,o1) -> `Field (f1, drop_offs o1)
          | `Index (i1,o1) -> `Index (i1, drop_offs o1)
          | `NoOffset -> `NoOffset
        in
        match Addr.to_var_offset x with
        | [(v,o)] -> Addr.from_var_offset (v, drop_offs o)
        | _ -> x
      in
      unlock (fun l -> remove_rw (drop_raw_lock l))
    | `Unlock, _ ->
      (*print_endline @@ "Mutex `Unlock "^f.vname;*)
      unlock remove_rw
    | _, "spinlock_check" -> ctx.local
    | _, "acquire_console_sem" when get_bool "kernel" ->
      ctx.emit (Events.Lock console_sem);
      Lockset.add (console_sem,true) ctx.local
    | _, "release_console_sem" when get_bool "kernel" ->
      ctx.emit (Events.Unlock console_sem);
      Lockset.remove (console_sem,true) ctx.local
    | _, "__builtin_prefetch" | _, "misc_deregister" ->
      ctx.local
    | _, "__VERIFIER_atomic_begin" when get_bool "ana.sv-comp.functions" ->
      ctx.emit (Events.Lock verifier_atomic);
      Lockset.add (verifier_atomic, true) ctx.local
    | _, "__VERIFIER_atomic_end" when get_bool "ana.sv-comp.functions" ->
      ctx.emit (Events.Unlock verifier_atomic);
      Lockset.remove (verifier_atomic, true) ctx.local
    | _, "pthread_cond_wait"
    | _, "pthread_cond_timedwait" ->
      (* mutex is unlocked while waiting but relocked when returns *)
      (* emit unlock-lock events for privatization *)
      let m_arg = List.nth arglist 1 in
      let ms = eval_exp_addr (Analyses.ask_of_ctx ctx) m_arg in
      List.iter (fun m ->
          (* unlock-lock each possible mutex as a split to be dependent *)
          (* otherwise may-point-to {a, b} might unlock a, but relock b *)
          ctx.split ctx.local [Events.Unlock m; Events.Lock m];
        ) ms;
      raise Deadcode (* splits cover all cases *)
    | _, x ->
      ctx.local

  let enter ctx lv f args : (D.t * D.t) list =
    [(ctx.local,ctx.local)]

  let combine ctx lv fexp f args fc al =
    al


  let threadspawn ctx lval f args fctx =
    ctx.local

  let init marshal =
    init marshal;
    arinc_analysis_activated := List.mem "arinc" (get_string_list "ana.activated")

end

module MyParam =
struct
  module G = LockDomain.Simple
  let effect_fun ?write:(w=false) ls = Lockset.export_locks ls
  let check_fun = effect_fun
end

module WriteBased =
struct
  module GReadWrite =
  struct
    include LockDomain.Simple
    let name () = "readwrite"
  end
  module GWrite =
  struct
    include LockDomain.Simple
    let name () = "write"
  end
  module G = Lattice.Prod (GReadWrite) (GWrite)
  let effect_fun ?write:(w=false) ls =
    let locks = Lockset.export_locks ls in
    (locks, if w then locks else Mutexes.top ())
  let check_fun ?write:(w=false) ls =
    let locks = Lockset.export_locks ls in
    if w then (Mutexes.bot (), locks) else (locks, Mutexes.bot ())
end

module Spec = MakeSpec (WriteBased)

let _ =
  MCP.register_analysis (module Spec : MCPSpec)
