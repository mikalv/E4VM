-- Handles input from BeamSParser and creates an Module which has separate
-- functions, and each opcode is converted to some Uassembly
module PassFromS where

import           BeamSTypes
import           UAssembly
import           UFunction
import           UModule

import           Control.Exception
import qualified Data.Map          as Map
import           Data.Maybe        (fromJust)
import           Data.Typeable

newtype CompileException =
  CompileException String
  deriving (Show, Typeable)

instance Exception CompileException

transform :: SExpr -> Either String Module
transform (SList l) =
  let mod0 = Module {umodName = "", umodFuns = Map.empty, umodExports = []}
  in let mod1 = transform' l mod0
     in Right mod1
transform other = Left $ show other

-- Returns True if a tuple is a {function, ...} otherwise False
isBeamSFunction :: SExpr -> Bool
isBeamSFunction (STuple (SAtom "function":_)) = True
isBeamSFunction _                             = False

-- Given list of tuples from BEAM S file handles header elements and then
-- takes functions one by one
transform' :: [SExpr] -> Module -> Module
transform' [] mod0 = mod0
transform' (STuple [SAtom "function", fname, farity, flabel]:tl) mod0 =
  let funs0 = UModule.umodFuns mod0
      tl1 = dropWhile (not . isBeamSFunction) tl
      fbody = takeWhile (not . isBeamSFunction) tl
      outFn = fnCreate fname farity flabel fbody
      funArity = sexprFunarity fname farity
      funs1 = Map.insert funArity outFn funs0
  in transform' tl1 mod0 {umodFuns = funs1}
transform' (STuple [SAtom "module", SAtom mname]:tl) mod0 =
  let mod1 = mod0 {umodName = mname}
  in transform' tl mod1
transform' (STuple [SAtom "exports", SList exps]:tl) mod0 =
  let exps1 = map (\(STuple [SAtom fn, SInt ar]) -> (fn, ar)) exps
      mod1 = mod0 {umodExports = exps1}
  in transform' tl mod1
-- ignored at the moment
transform' (STuple [SAtom "attributes", SList _mattr]:tl) mod0 =
  transform' tl mod0
transform' (STuple [SAtom "labels", _]:tl) mod0 = transform' tl mod0
transform' (form:_tl) _mod0 =
  error ("unexpected form in the input S file: " ++ show form)

-- Given F/Arity and code body return a Function object
fnCreate :: SExpr -> SExpr -> SExpr -> [SExpr] -> Function
fnCreate (SAtom fname) (SInt farity) (SInt _flabel) fbody =
  let asmBody = transformCode fbody []
  in Function {ufunName = fname, ufunArity = farity, ufunBody = asmBody}
fnCreate _f _a _label _body = error "parseFn expects a function"

readLoc :: SExpr -> Maybe ReadLoc
readLoc (STuple [SAtom "x", SInt x])    = Just $ RRegX (fromIntegral x)
readLoc (STuple [SAtom "y", SInt y])    = Just $ RRegY (fromIntegral y)
readLoc (STuple [SAtom "literal", lit]) = Just $ RLit lit
readLoc (STuple [SAtom "atom", a])      = Just $ RAtom a
readLoc (SAtom "nil")                   = Just RNil
readLoc (SInt i)                        = Just $ RInt i
readLoc other                           = Just $ ReadLocError $ show other

writeLoc :: SExpr -> Maybe WriteLoc
writeLoc (STuple [SAtom "x", SInt x]) = Just $ WRegX (fromIntegral x)
writeLoc (STuple [SAtom "y", SInt y]) = Just $ WRegY (fromIntegral y)
writeLoc other                        = Just $ WriteLocError $ show other

parseLabel :: SExpr -> ULbl
parseLabel (STuple [SAtom "f", SInt 0]) = UNoLabel
parseLabel (STuple [SAtom "f", SInt i]) = ULbl $ fromIntegral i
parseLabel other = throw ex
  where
    ex = CompileException ("not a label" ++ show other)

parseChoices :: [SExpr] -> [(SExpr, ULbl)] -> [(SExpr, ULbl)]
parseChoices [] acc = reverse acc
parseChoices [_] _acc = throw ex
  where ex = CompileException "parseChoices given a list of odd length"
parseChoices (val : lbl : tl) acc =
  parseChoices tl acc1
  where ulbl = parseLabel lbl
        acc1 = (val, ulbl) : acc

transformCode :: [SExpr] -> [UAsmOp] -> [UAsmOp]
transformCode [] acc = reverse acc
transformCode (STuple [SAtom "label", f]:tl) acc = transformCode tl (op : acc)
  where
    Just nlabel = sexprInt f
    op = UAssembly.label nlabel
transformCode (STuple [SAtom "line", _]:tl) acc = transformCode tl acc
transformCode (STuple [SAtom "move", src, dst]:tl) acc =
  transformCode tl (UAssembly.move usrc udst : acc)
  where
    Just usrc = readLoc src
    Just udst = writeLoc dst
transformCode (STuple [SAtom "get_list", src, hddst, tldst]:tl) acc =
  transformCode tl (op : acc)
  where
    Just usrc = readLoc src
    Just uhd = writeLoc hddst
    Just utl = writeLoc tldst
    op = UAssembly.decons usrc uhd utl
transformCode (STuple [SAtom "func_info", _mod, _fun, _arity]:tl) acc =
  transformCode tl (UAssembly.funcClause : acc)
transformCode (STuple [SAtom "badmatch", val]:tl) acc =
  transformCode tl (op : acc)
  where
    Just uval = readLoc val
    op = UAssembly.badmatch uval
transformCode (STuple [SAtom "put_tuple", sz, dst]:tl) acc =
  transformCode tl (UAssembly.tupleNew usz udst : acc)
  where
    Just udst = writeLoc dst
    Just usz = sexprInt sz
transformCode (STuple [SAtom "put", val]:tl) acc =
  transformCode tl (UAssembly.tuplePut uval : acc)
  where
    Just uval = readLoc val
transformCode (STuple [SAtom "get_tuple_element", src, indx, dst]:tl) acc =
  transformCode tl (UAssembly.tupleGetEl usrc uindx udst : acc)
  where
    Just usrc = readLoc src
    Just uindx = readLoc indx
    Just udst = writeLoc dst
transformCode (STuple [SAtom opname, stkneed, live]:tl) acc
  | opname == "allocate" || opname == "allocate_zero" =
    transformCode tl (op : acc)
  where
    Just ustkneed = sexprInt stkneed
    Just ulive = sexprInt live
    op = UAssembly.allocate ustkneed ulive
transformCode (STuple [SAtom "deallocate", n]:SAtom "return":tl) acc =
  transformCode tl (UAssembly.ret un : acc)
  where
    Just un = sexprInt n
transformCode (STuple [SAtom "deallocate", n]:tl) acc =
  transformCode tl (UAssembly.deallocate un : acc)
  where
    Just un = sexprInt n
transformCode (SAtom "return":tl) acc = transformCode tl (op : acc)
  where
    op = UAssembly.ret 0
transformCode (STuple [SAtom "test", SAtom testName, fail1, SList args]:tl) acc =
  transformCode tl (op : acc)
  where
    ufail = parseLabel fail1
    uargs = map (fromJust . readLoc) args
    op = UAssembly.test testName ufail uargs
transformCode (STuple [SAtom "call_ext", _arity,
                       STuple [SAtom "extfunc", SAtom m, SAtom f, arity]]:tl) acc =
  transformCode tl (op : acc)
  where
    Just uarity = sexprInt arity
    op = UAssembly.callExt (m, f, uarity) NormalCall
transformCode (STuple [SAtom "call", arity, dst]:tl) acc =
  transformCode tl (op : acc)
  where
    udst = parseLabel dst
    Just uarity = sexprInt arity
    op = UAssembly.callLabel uarity udst NormalCall
transformCode (STuple [SAtom "call_last", arity, dst, deallc]:tl) acc =
  transformCode tl (op : acc)
  where
    udst = parseLabel dst
    Just uarity = sexprInt arity
    Just udeallc = sexprInt deallc
    op = UAssembly.callLabel uarity udst (TailCallDealloc udeallc)
transformCode (STuple [SAtom "gc_bif",
                       SAtom bifName, onfail, _arity, SList args, dst]:tl) acc =
  transformCode tl (op : acc)
  where
    ufail = parseLabel onfail
    Just udst = writeLoc dst
    uargs = map (fromJust . readLoc) args
    op = UAssembly.callBif bifName ufail uargs NormalCall udst
transformCode (STuple [SAtom "test_heap", need, live]:tl) acc =
  transformCode tl (op : acc)
  where
    Just uneed = sexprInt need
    Just ulive = sexprInt live
    op = UAssembly.testHeap uneed ulive
transformCode (STuple [SAtom "select_val", src, onfail, STuple [SAtom "list", SList choices]]:tl) acc =
  transformCode tl (op : acc)
  where
    Just usrc = readLoc src
    ufail = parseLabel onfail
    uchoices = parseChoices choices []
    op = UAssembly.select usrc ufail uchoices
transformCode (other:_tl) _acc = throw ex
  where
    ex = CompileException ("don't know how to transform " ++ show other)
