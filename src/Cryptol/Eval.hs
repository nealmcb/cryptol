-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE Safe #-}
{-# LANGUAGE PatternGuards #-}

module Cryptol.Eval (
    moduleEnv
  , EvalEnv()
  , emptyEnv
  , evalExpr
  , evalDecls
  , EvalError(..)
  ) where

import Cryptol.Eval.Env
import Cryptol.Eval.Monad
import Cryptol.Eval.Type
import Cryptol.Eval.Value
import Cryptol.ModuleSystem.Name
import Cryptol.TypeCheck.AST
import Cryptol.TypeCheck.Solver.InfNat(Nat'(..))
import Cryptol.Utils.Ident (Ident)
import Cryptol.Utils.Panic (panic)
import Cryptol.Utils.PP
import Cryptol.Prims.Eval

import           Control.Monad
import           Control.Monad.Fix
import           Data.IORef
import           Data.List
import qualified Data.Map.Strict as Map

import Prelude ()
import Prelude.Compat

-- Expression Evaluation -------------------------------------------------------

moduleEnv :: Module -> EvalEnv -> Eval EvalEnv
moduleEnv m env = evalDecls (mDecls m) =<< evalNewtypes (mNewtypes m) env

evalExpr :: EvalEnv -> Expr -> Eval Value
evalExpr env expr = case expr of

  EList es ty ->
    VSeq (genericLength es) (isTBit (evalType env ty))
       <$> finiteSeqMap (map (evalExpr env) es)

  ETuple es -> do
     xs <- mapM (delay Nothing . eval) es
     return $ VTuple xs

  ERec fields -> do
     xs <- sequence [ do thk <- delay Nothing (eval e)
                         return (f,thk)
                    | (f,e) <- fields
                    ]
     return $ VRecord xs

  ESel e sel -> do
     x <- eval e
     evalSel x sel

  EIf c t f -> do
     b <- fromVBit <$> eval c
     if b then
       eval t
     else
       eval f

  EComp n t h gs -> do
      let len  = evalType env n
      let elty = evalType env t
      evalComp env len elty h gs

  EVar n -> do
    case lookupVar n env of
      Just val -> val
      Nothing  -> do
        envdoc <- ppEnv defaultPPOpts env
        panic "[Eval] evalExpr"
                     ["var `" ++ show (pp n) ++ "` is not defined"
                     , show envdoc
                     ]

  ETAbs tv b ->
     return $ VPoly $ \ty -> evalExpr (bindType (tpVar tv) ty env) b

  ETApp e ty -> do
    eval e >>= \case
      VPoly f -> f $! (evalType env ty)
      val     -> do vdoc <- ppV val
                    panic "[Eval] evalExpr"
                      ["expected a polymorphic value"
                      , show vdoc, show e, show ty
                      ]

  EApp f x -> do
    eval f >>= \case
      VFun f' -> f' (eval x)
      it      -> do itdoc <- ppV it
                    panic "[Eval] evalExpr" ["not a function", show itdoc ]

  EAbs n _ty b ->
    return $ VFun (\v -> do env' <- bindVar n v env
                            evalExpr env' b)

  -- XXX these will likely change once there is an evidence value
  EProofAbs _ e -> evalExpr env e
  EProofApp e   -> evalExpr env e

  ECast e _ty -> evalExpr env e

  EWhere e ds -> do
     env' <- evalDecls ds env
     evalExpr env' e

  where

  eval = evalExpr env
  ppV = ppValue defaultPPOpts


-- Newtypes --------------------------------------------------------------------

evalNewtypes :: Map.Map Name Newtype -> EvalEnv -> Eval EvalEnv
evalNewtypes nts env = foldM (flip evalNewtype) env $ Map.elems nts

-- | Introduce the constructor function for a newtype.
evalNewtype :: Newtype -> EvalEnv -> Eval EvalEnv
evalNewtype nt = bindVar (ntName nt) (return (foldr tabs con (ntParams nt)))
  where
  tabs _tp body = tlam (\ _ -> body)
  con           = VFun id


-- Declarations ----------------------------------------------------------------

evalDecls :: [DeclGroup] -> EvalEnv -> Eval EvalEnv
evalDecls dgs env = foldM evalDeclGroup env dgs

evalDeclGroup :: EvalEnv -> DeclGroup -> Eval EvalEnv
evalDeclGroup env dg = do
  case dg of
    Recursive ds -> do
      -- declare a "hole" for each declaration
      holes <- mapM declHole ds
      let holeEnv = Map.fromList $ [ (nm,h) | (nm,h,_) <- holes ]
      let env' = env `mappend` emptyEnv{ envVars = holeEnv }

      -- evaluate the declaration bodies
      env'' <- foldM (evalDecl env') env ds

      -- now backfill the holes we declared earlier
      mapM_ (fillHole env'') holes

      -- return the map containing the holes
      return env'

    NonRecursive d -> do
      evalDecl env env d

fillHole :: EvalEnv -> (Name, Eval Value, Eval Value -> Eval ()) -> Eval ()
fillHole env (nm, _, fill) = do
  case lookupVar nm env of
    Nothing -> evalPanic "fillHole" ["Recursive definition not completed", show (ppLocName nm)]
    Just x  -> fill =<< delay (Just (show (ppLocName nm))) x

declHole :: Decl -> Eval (Name, Eval Value, Eval Value -> Eval ())
declHole d =
  case dDefinition d of
    DPrim   -> evalPanic "Unexpected primitive declaration in recursive group"
                         [show (ppLocName nm)]
    DExpr e -> do
      (hole, fill) <- blackhole msg
      return (nm, hole, fill)
 where
 nm = dName d
 msg = unwords ["<<loop>> while evaluating", show (pp nm)]


evalDecl :: ReadEnv -> EvalEnv -> Decl -> Eval EvalEnv
evalDecl renv env d = bindVar (dName d) f env
 where
 f = case dDefinition d of
       DPrim   -> return $ evalPrim d
       DExpr e -> evalExpr renv e


-- Selectors -------------------------------------------------------------------

evalSel :: Value -> Selector -> Eval Value
evalSel val sel = case sel of

  TupleSel n _  -> tupleSel n val
  RecordSel n _ -> recordSel n val
  ListSel ix _  -> do xs <- fromSeq val
                      lookupSeqMap xs (toInteger ix)

  where

  tupleSel :: Int -> Value -> Eval Value
  tupleSel n v =
    case v of
      VTuple vs       -> vs !! n
      VSeq w False vs -> VSeq w False <$> mapSeqMap (tupleSel n) vs
      VStream vs      -> VStream <$> mapSeqMap (tupleSel n) vs
      VFun f          -> return $ VFun (\x -> tupleSel n =<< f x)
      _               -> do vdoc <- ppValue defaultPPOpts v
                            evalPanic "Cryptol.Eval.evalSel"
                             [ "Unexpected value in tuple selection"
                             , show vdoc ]

  recordSel :: Ident -> Value -> Eval Value
  recordSel n v =
    case v of
      VRecord {}      -> lookupRecord n v
      VSeq w False vs -> VSeq w False <$> mapSeqMap (recordSel n) vs
      VStream vs      -> VStream <$> mapSeqMap (recordSel n) vs
      VFun f          -> return $ VFun (\x -> recordSel n =<< f x)
      _               -> do vdoc <- ppValue defaultPPOpts v
                            evalPanic "Cryptol.Eval.evalSel"
                             [ "Unexpected value in record selection"
                             , show vdoc ]





-- List Comprehension Environments ---------------------------------------------

-- | Evaluation environments for list comprehensions: Each variable
-- name is bound to a list of values, one for each element in the list
-- comprehension.
data ListEnv = ListEnv
  { leVars   :: !(Map.Map Name (Integer -> Eval Value))
      -- ^ Bindings whose values vary by position
  , leStatic :: !(Map.Map Name (Eval Value))
      -- ^ Bindings whose values are constant
  , leTypes  :: !(Map.Map TVar TValue)
  }

instance Monoid ListEnv where
  mempty = ListEnv
    { leVars   = Map.empty
    , leStatic = Map.empty
    , leTypes  = Map.empty
    }

  mappend l r = ListEnv
    { leVars   = Map.union (leVars  l)  (leVars  r)
    , leStatic = Map.union (leStatic l) (leStatic r)
    , leTypes  = Map.union (leTypes l)  (leTypes r)
    }

toListEnv :: EvalEnv -> ListEnv
toListEnv e =
  ListEnv
  { leVars   = mempty
  , leStatic = envVars e
  , leTypes  = envTypes e
  }

-- | Evaluate a list environment at a position.
--   This choses a particular value for the varying
--   locations.
evalListEnv :: ListEnv -> Integer -> EvalEnv
evalListEnv (ListEnv vm st tm) i =
    let v = fmap ($i) vm
     in EvalEnv{ envVars = Map.union v st
               , envTypes = tm
               }

bindVarList :: Name -> (Integer -> Eval Value) -> ListEnv -> ListEnv
bindVarList n vs lenv = lenv { leVars = Map.insert n vs (leVars lenv) }

-- List Comprehensions ---------------------------------------------------------

-- | Evaluate a comprehension.
evalComp :: ReadEnv -> TValue -> TValue -> Expr -> [[Match]] -> Eval Value
evalComp env len elty body ms =
       do lenv <- mconcat <$> mapM (branchEnvs (toListEnv env)) ms
          seq <- memoMap $ SeqMap $ \i -> do
              evalExpr (evalListEnv lenv i) body
          return $ mkSeq len elty $ seq

-- | Turn a list of matches into the final environments for each iteration of
-- the branch.
branchEnvs :: ListEnv -> [Match] -> Eval ListEnv
branchEnvs env matches = foldM evalMatch env matches

-- | Turn a match into the list of environments it represents.
evalMatch :: ListEnv -> Match -> Eval ListEnv
evalMatch lenv m = case m of

  -- many envs
  From n l ty expr ->
    case numTValue len of
      Nat nLen -> do
        vss <- memoMap $ SeqMap $ \i -> evalExpr (evalListEnv lenv i) expr
        let stutter xs = \i -> xs (i `div` nLen)
        let lenv' = lenv { leVars = fmap stutter (leVars lenv) }
        let vs i = do let (q, r) = i `divMod` nLen
                      xs <- fromSeq =<< lookupSeqMap vss q
                      lookupSeqMap xs r
        return $ bindVarList n vs lenv'

      Inf -> do
        let allvars = Map.union (fmap ($0) (leVars lenv)) (leStatic lenv)
        let lenv' = lenv { leVars   = Map.empty
                         , leStatic = allvars
                         }
        let env   = EvalEnv allvars (leTypes lenv)
        xs <- delay Nothing (fromSeq =<< evalExpr env expr)
        let vs i = do xseq <- xs
                      lookupSeqMap xseq i
        return $ bindVarList n vs lenv'

    where
      tyenv = emptyEnv{ envTypes = leTypes lenv }
      len  = evalType tyenv l

  -- XXX we don't currently evaluate these as though they could be recursive, as
  -- they are typechecked that way; the read environment to evalExpr is the same
  -- as the environment to bind a new name in.
  Let d -> return $ bindVarList (dName d) (\i -> f (evalListEnv lenv i)) lenv
    where
      f env =
          case dDefinition d of
            DPrim   -> return $ evalPrim d
            DExpr e -> evalExpr env e
