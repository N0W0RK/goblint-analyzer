open Analyses

module Query
    (Spec : Spec)
    (EQSys : GlobConstrSys with module LVar = VarF (Spec.C)
                            and module GVar = GVarF (Spec.V)
                            and module D = Spec.D
                            and module G = GVarG (Spec.G) (Spec.C))
    (GHT : BatHashtbl.S with type key = EQSys.GVar.t) =
struct
  let ask_local (gh: EQSys.G.t GHT.t) (lvar:EQSys.LVar.t) local =
    (* build a ctx for using the query system *)
    let rec ctx =
      { ask    = (fun (type a) (q: a Queries.t) -> Spec.query ctx q)
      ; emit   = (fun _ -> failwith "Cannot \"emit\" in witness context.")
      ; node   = fst lvar
      ; prev_node = MyCFG.dummy_node
      ; control_context = (fun () -> Obj.magic (snd lvar)) (* magic is fine because Spec is top-level Control Spec *)
      ; context = (fun () -> snd lvar)
      ; edge    = MyCFG.Skip
      ; local  = local
      ; global = (fun g -> try EQSys.G.spec (GHT.find gh (EQSys.GVar.spec g)) with Not_found -> Spec.G.bot ()) (* see 29/29 on why fallback is needed *)
      ; spawn  = (fun v d    -> failwith "Cannot \"spawn\" in witness context.")
      ; split  = (fun d es   -> failwith "Cannot \"split\" in witness context.")
      ; sideg  = (fun v g    -> failwith "Cannot \"sideg\" in witness context.")
      }
    in
    Spec.query ctx

  let ask_local_node (gh: EQSys.G.t GHT.t) (n: Node.t) local =
    (* build a ctx for using the query system *)
    let rec ctx =
      { ask    = (fun (type a) (q: a Queries.t) -> Spec.query ctx q)
      ; emit   = (fun _ -> failwith "Cannot \"emit\" in witness context.")
      ; node   = n
      ; prev_node = MyCFG.dummy_node
      ; control_context = (fun () -> ctx_failwith "No context in witness context.")
      ; context = (fun () -> ctx_failwith "No context in witness context.")
      ; edge    = MyCFG.Skip
      ; local  = local
      ; global = (fun g -> try EQSys.G.spec (GHT.find gh (EQSys.GVar.spec g)) with Not_found -> Spec.G.bot ()) (* TODO: how can be missing? *)
      ; spawn  = (fun v d    -> failwith "Cannot \"spawn\" in witness context.")
      ; split  = (fun d es   -> failwith "Cannot \"split\" in witness context.")
      ; sideg  = (fun v g    -> failwith "Cannot \"sideg\" in witness context.")
      }
    in
    Spec.query ctx

  let ask_global (gh: EQSys.G.t GHT.t) =
    (* copied from Control for WarnGlobal *)
    (* build a ctx for using the query system *)
    let rec ctx =
      { ask    = (fun (type a) (q: a Queries.t) -> Spec.query ctx q)
      ; emit   = (fun _ -> failwith "Cannot \"emit\" in query context.")
      ; node   = MyCFG.dummy_node (* TODO maybe ask should take a node (which could be used here) instead of a location *)
      ; prev_node = MyCFG.dummy_node
      ; control_context = (fun () -> ctx_failwith "No context in query context.")
      ; context = (fun () -> ctx_failwith "No context in query context.")
      ; edge    = MyCFG.Skip
      ; local  = Spec.startstate GoblintCil.dummyFunDec.svar (* bot and top both silently raise and catch Deadcode in DeadcodeLifter *) (* TODO: is this startstate bad? *)
      ; global = (fun v -> EQSys.G.spec (try GHT.find gh (EQSys.GVar.spec v) with Not_found -> EQSys.G.bot ())) (* TODO: how can be missing? *)
      ; spawn  = (fun v d    -> failwith "Cannot \"spawn\" in query context.")
      ; split  = (fun d es   -> failwith "Cannot \"split\" in query context.")
      ; sideg  = (fun v g    -> failwith "Cannot \"split\" in query context.")
      }
    in
    Spec.query ctx
end
