(** Domains for [setjmp] and [longjmp] analyses, and [setjmp] buffers. *)

module BufferEntry = Printable.ProdSimple(Node)(ControlSpecC)

module BufferEntryOrTop = struct
  include Printable.Std
  type t = AllTargets | Target of BufferEntry.t [@@deriving eq, ord, hash, to_yojson]

  let name () = "jmpbuf entry"

  let relift = function
    | AllTargets -> AllTargets
    | Target x -> Target (BufferEntry.relift x)

  let show = function AllTargets -> "All" | Target x -> BufferEntry.show x

  include Printable.SimpleShow (struct
      type nonrec t = t
      let show = show
    end)
end

module JmpBufSet =
struct
  include SetDomain.Make (BufferEntryOrTop)
  let top () = singleton BufferEntryOrTop.AllTargets
  let name () = "Jumpbuffers"

  let inter x y =
    if mem BufferEntryOrTop.AllTargets x || mem BufferEntryOrTop.AllTargets y then
      let fromx = if mem BufferEntryOrTop.AllTargets y then x else bot () in
      let fromy = if mem BufferEntryOrTop.AllTargets x then y else bot () in
      union fromx fromy
    else
      inter x y

  let meet = inter
end

module JmpBufSetTaintInvalid =
struct
  module Bufs = JmpBufSet
  include Lattice.Prod3(JmpBufSet)(BoolDomain.MayBool)(BoolDomain.MayBool)
  let buffers (buffer,_,_) = buffer
  let copied (_,copied,_) = copied
  let invalid (_,_,invalid) = invalid
  let name () = "JumpbufferTaintOrInvalid"
end


(* module JmpBufSet =
   struct
   include SetDomain.ToppedSet (BufferEntry) (struct let topname = "All jumpbufs" end)
   let name () = "Jumpbuffers"
   end *)

module NodeSet =
struct
  include SetDomain.ToppedSet (Node) (struct let topname = "All longjmp callers" end)
  let name () = "Longjumps"
end

module ActiveLongjmps =
struct
  include Lattice.ProdSimple(JmpBufSet)(NodeSet)
end

module LocallyModifiedMap =
struct
  module VarSet = SetDomain.ToppedSet(CilType.Varinfo) (struct let topname = "All vars" end)
  include MapDomain.MapBot_LiftTop (BufferEntry)(VarSet)

  let name () = "Locally modified variables since the corresponding setjmp"
end
