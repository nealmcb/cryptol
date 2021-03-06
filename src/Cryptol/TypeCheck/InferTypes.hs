-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable
--
-- This module contains types used during type inference.

{-# LANGUAGE Safe #-}

{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
module Cryptol.TypeCheck.InferTypes where

import           Cryptol.TypeCheck.AST
import           Cryptol.TypeCheck.Subst
import           Cryptol.Parser.Position
import qualified Cryptol.Parser.AST as P
import           Cryptol.Utils.PP
import           Cryptol.ModuleSystem.Name (asPrim,nameLoc)
import           Cryptol.TypeCheck.PP
import           Cryptol.Utils.Ident (Ident,identText)
import           Cryptol.Utils.Panic(panic)
import           Cryptol.Utils.Misc(anyJust)

import           Data.Set ( Set )
import qualified Data.Set as Set
import qualified Data.IntMap as IntMap

import GHC.Generics (Generic)
import Control.DeepSeq
import Data.List ((\\))

data SolverConfig = SolverConfig
  { solverPath    :: FilePath   -- ^ The SMT solver to invoke
  , solverArgs    :: [String]   -- ^ Additional arguments to pass to the solver
  , solverVerbose :: Int        -- ^ How verbose to be when type-checking
  , solverPreludePath :: [FilePath]
    -- ^ Look for the solver prelude in these locations.
  } deriving (Show, Generic, NFData)

-- | The types of variables in the environment.
data VarType = ExtVar Schema
               -- ^ Known type

             | CurSCC {- LAZY -} Expr Type
               {- ^ Part of current SCC.  The expression will replace the
               variable, after we are done with the SCC.  In this way a
               variable that gets generalized is replaced with an approproate
               instantiations of itslef. -}

-- XXX: Temporary, until we figure out, how to apply substitutions
-- with normalization to the type Map
newtype Goals = Goals (Set Goal) -- Goals (TypeMap Goal)
                deriving (Show)

emptyGoals :: Goals
emptyGoals  = Goals Set.empty -- emptyTM

nullGoals :: Goals -> Bool
nullGoals (Goals tm) = Set.null tm -- nullTM tm

fromGoals :: Goals -> [Goal]
fromGoals (Goals tm) = Set.toList tm -- membersTM tm

insertGoal :: Goal -> Goals -> Goals
insertGoal g (Goals tm) = Goals (Set.insert g tm) -- (insertTM (goal g) g tm)

-- | Something that we need to find evidence for.
data Goal = Goal
  { goalSource :: ConstraintSource  -- ^ What it is about
  , goalRange  :: Range             -- ^ Part of source code that caused goal
  , goal       :: Prop              -- ^ What needs to be proved
  } deriving (Show, Generic, NFData)

instance Eq Goal where
  x == y = goal x == goal y

instance Ord Goal where
  compare x y = compare (goal x) (goal y)

data HasGoal = HasGoal
  { hasName :: !Int
  , hasGoal :: Goal
  } deriving Show

-- | Delayed implication constraints, arising from user-specified type sigs.
data DelayedCt = DelayedCt
  { dctSource :: Name   -- ^ Signature that gave rise to this constraint
  , dctForall :: [TParam]
  , dctAsmps  :: [Prop]
  , dctGoals  :: [Goal]
  } deriving (Show, Generic, NFData)

data Warning  = DefaultingKind (P.TParam Name) P.Kind
              | DefaultingWildType P.Kind
              | DefaultingTo Doc Type
                deriving (Show, Generic, NFData)

-- | Various errors that might happen during type checking/inference
data Error    = ErrorMsg Doc
                -- ^ Just say this

              | KindMismatch Kind Kind
                -- ^ Expected kind, inferred kind

              | TooManyTypeParams Int Kind
                -- ^ Number of extra parameters, kind of result
                -- (which should not be of the form @_ -> _@)

              | TooManyTySynParams Name Int
                -- ^ Type-synonym, number of extra params

              | TooFewTySynParams Name Int
                -- ^ Type-synonym, number of missing params

              | RepeatedTyParams [P.TParam Name]
                -- ^ Type parameters with the same name (in definition)

              | RepeatedDefinitions Name [Range]
                -- ^ Multiple definitions for the same name

              | RecursiveTypeDecls [Name]
                -- ^ The type synonym declarations are recursive

              | UndefinedTypeSynonym Name
                -- ^ Use of a type synonym that was not defined

              | UndefinedVariable Name
                -- ^ Use of a variable that was not defined

              | UndefinedTypeParam (Located Ident)
                -- ^ Attempt to explicitly instantiate a non-existent param.

              | MultipleTypeParamDefs Ident [Range]
                -- ^ Multiple definitions for the same type parameter

              | TypeMismatch Type Type
                -- ^ Expected type, inferred type

              | RecursiveType Type Type
                -- ^ Unification results in a recursive type

              | UnsolvedGoals Bool [Goal]
                -- ^ A constraint that we could not solve
                -- The boolean indicates if we know that this constraint
                -- is impossible.

              | UnsolvedDelayedCt DelayedCt
                -- ^ A constraint (with context) that we could not solve

              | UnexpectedTypeWildCard
                -- ^ Type wild cards are not allowed in this context
                -- (e.g., definitions of type synonyms).

              | TypeVariableEscaped Type [TVar]
                -- ^ Unification variable depends on quantified variables
                -- that are not in scope.

              | NotForAll TVar Type
                -- ^ Quantified type variables (of kind *) need to
                -- match the given type, so it does not work for all types.

              | UnusableFunction Name [Prop]
                -- ^ The given constraints causes the signature of the
                -- function to be not-satisfiable.

              | TooManyPositionalTypeParams
                -- ^ Too many positional type arguments, in an explicit
                -- type instantiation

              | CannotMixPositionalAndNamedTypeParams

              | AmbiguousType [Name]


                deriving (Show, Generic, NFData)

-- | Information about how a constraint came to be, used in error reporting.
data ConstraintSource
  = CtComprehension       -- ^ Computing shape of list comprehension
  | CtSplitPat            -- ^ Use of a split pattern
  | CtTypeSig             -- ^ A type signature in a pattern or expression
  | CtInst Expr           -- ^ Instantiation of this expression
  | CtSelector
  | CtExactType
  | CtEnumeration
  | CtDefaulting          -- ^ Just defaulting on the command line
  | CtPartialTypeFun TyFunName -- ^ Use of a partial type function.
  | CtImprovement
  | CtPattern Doc         -- ^ Constraints arising from type-checking patterns
    deriving (Show, Generic, NFData)

data TyFunName = UserTyFun Name | BuiltInTyFun TFun
                deriving (Show, Generic, NFData)

instance PP TyFunName where
  ppPrec c (UserTyFun x)    = ppPrec c x
  ppPrec c (BuiltInTyFun x) = ppPrec c x

instance TVars ConstraintSource where
  apSubst su src =
    case src of
      CtComprehension -> src
      CtSplitPat      -> src
      CtTypeSig       -> src
      CtInst e        -> CtInst (apSubst su e)
      CtSelector      -> src
      CtExactType     -> src
      CtEnumeration   -> src
      CtDefaulting    -> src
      CtPartialTypeFun _ -> src
      CtImprovement    -> src
      CtPattern _      -> src

instance TVars Warning where
  apSubst su warn =
    case warn of
      DefaultingKind {}     -> warn
      DefaultingWildType {} -> warn
      DefaultingTo d ty     -> DefaultingTo d (apSubst su ty)

instance FVS Warning where
  fvs warn =
    case warn of
      DefaultingKind {}     -> Set.empty
      DefaultingWildType {} -> Set.empty
      DefaultingTo _ ty     -> fvs ty



instance TVars Error where
  apSubst su err =
    case err of
      ErrorMsg _                -> err
      KindMismatch {}           -> err
      TooManyTypeParams {}      -> err
      TooManyTySynParams {}     -> err
      TooFewTySynParams {}      -> err
      RepeatedTyParams {}       -> err
      RepeatedDefinitions {}    -> err
      RecursiveTypeDecls {}     -> err
      UndefinedTypeSynonym {}   -> err
      UndefinedVariable {}      -> err
      UndefinedTypeParam {}     -> err
      MultipleTypeParamDefs {}  -> err
      TypeMismatch t1 t2        -> TypeMismatch (apSubst su t1) (apSubst su t2)
      RecursiveType t1 t2       -> RecursiveType (apSubst su t1) (apSubst su t2)
      UnsolvedGoals x gs        -> UnsolvedGoals x (apSubst su gs)
      UnsolvedDelayedCt g       -> UnsolvedDelayedCt (apSubst su g)
      UnexpectedTypeWildCard    -> err
      TypeVariableEscaped t xs  -> TypeVariableEscaped (apSubst su t) xs
      NotForAll x t             -> NotForAll x (apSubst su t)
      UnusableFunction f ps      -> UnusableFunction f (apSubst su ps)
      TooManyPositionalTypeParams -> err
      CannotMixPositionalAndNamedTypeParams -> err
      AmbiguousType _           -> err

instance FVS Error where
  fvs err =
    case err of
      ErrorMsg {}               -> Set.empty
      KindMismatch {}           -> Set.empty
      TooManyTypeParams {}      -> Set.empty
      TooManyTySynParams {}     -> Set.empty
      TooFewTySynParams {}      -> Set.empty
      RepeatedTyParams {}       -> Set.empty
      RepeatedDefinitions {}    -> Set.empty
      RecursiveTypeDecls {}     -> Set.empty
      UndefinedTypeSynonym {}   -> Set.empty
      UndefinedVariable {}      -> Set.empty
      UndefinedTypeParam {}     -> Set.empty
      MultipleTypeParamDefs {}  -> Set.empty
      TypeMismatch t1 t2        -> fvs (t1,t2)
      RecursiveType t1 t2       -> fvs (t1,t2)
      UnsolvedGoals _ gs        -> fvs gs
      UnsolvedDelayedCt g       -> fvs g
      UnexpectedTypeWildCard    -> Set.empty
      TypeVariableEscaped t _   -> fvs t
      NotForAll _ t             -> fvs t
      UnusableFunction _ p      -> fvs p
      TooManyPositionalTypeParams -> Set.empty
      CannotMixPositionalAndNamedTypeParams -> Set.empty
      AmbiguousType _           ->  Set.empty

instance FVS Goal where
  fvs g = fvs (goal g)

instance FVS DelayedCt where
  fvs d = fvs (dctAsmps d, dctGoals d) `Set.difference`
                            Set.fromList (map tpVar (dctForall d))


-- This first applies the substitution to the keys of the goal map, then to the
-- values that remain, as applying the substitution to the keys will only ever
-- reduce the number of values that remain.
instance TVars Goals where
  apSubst su (Goals gs) = case anyJust apG (Set.toList gs) of
                            Nothing -> Goals gs
                            Just gs1 -> Goals $ Set.fromList
                                              $ concatMap norm gs1
    where
    norm g = [ g { goal = p } | p <- pSplitAnd (goal g) ]
    apG g  = mk g <$> apSubstMaybe su (goal g)
    mk g p = g { goal = p }

{-
  apSubst su (Goals gs) = Goals (Set.fromList . mapAp

  apSubst su (Goals goals) =
    Goals (mapWithKeyTM setGoal (apSubstTypeMapKeys su goals))
    where
    -- as the key for the goal map is the same as the goal, and the substitution
    -- has been applied to the key already, just replace the existing goal with
    -- the key.
    setGoal key g = g { goalSource = apSubst su (goalSource g)
                      , goal       = key
                      }
-}

instance TVars Goal where
  apSubst su g = Goal { goalSource = apSubst su (goalSource g)
                      , goalRange  = goalRange g
                      , goal       = apSubst su (goal g)
                      }

instance TVars HasGoal where
  apSubst su h = h { hasGoal = apSubst su (hasGoal h) }

instance TVars DelayedCt where
  apSubst su g
    | Set.null captured =
       DelayedCt { dctSource = dctSource g
                 , dctForall = dctForall g
                 , dctAsmps  = apSubst su (dctAsmps g)
                 , dctGoals  = apSubst su (dctGoals g)
                 }

    | otherwise = panic "Cryptol.TypeCheck.Subst.apSubst (DelayedCt)"
                    [ "Captured quantified variables:"
                    , "Substitution: " ++ show su
                    , "Variables:    " ++ show captured
                    , "Constraint:   " ++ show g
                    ]

    where
    captured = Set.fromList (map tpVar (dctForall g))
               `Set.intersection`
               subVars
    subVars = Set.unions
                $ map (fvs . applySubstToVar su)
                $ Set.toList used
    used = fvs (dctAsmps g, map goal (dctGoals g)) `Set.difference`
                Set.fromList (map tpVar (dctForall g))

-- | For use in error messages
cppKind :: Kind -> Doc
cppKind ki =
  case ki of
    KNum  -> text "a numeric type"
    KType -> text "a value type"
    KProp -> text "a constraint"
    _     -> pp ki

addTVarsDescs :: FVS t => NameMap -> t -> Doc -> Doc
addTVarsDescs nm t d
  | Set.null vs = d
  | otherwise   = d $$ text "where" $$ vcat (map desc (Set.toList vs))
  where
  vs                      = Set.filter isFreeTV (fvs t)
  desc v@(TVFree _ _ _ x) = ppWithNames nm v <+> text "is" <+> x
  desc (TVBound {})       = empty



instance PP Warning where
  ppPrec = ppWithNamesPrec IntMap.empty

instance PP Error where
  ppPrec = ppWithNamesPrec IntMap.empty


instance PP (WithNames Warning) where
  ppPrec _ (WithNames warn names) =
    addTVarsDescs names warn $
    case warn of
      DefaultingKind x k ->
        text "Assuming " <+> pp x <+> text "to have" <+> P.cppKind k

      DefaultingWildType k ->
        text "Assuming _ to have" <+> P.cppKind k

      DefaultingTo d ty ->
        text "Defaulting" <+> d $$ text "to" <+> ppWithNames names ty

instance PP (WithNames Error) where
  ppPrec _ (WithNames err names) =
    addTVarsDescs names err $
    case err of
      ErrorMsg msg -> msg

      RecursiveType t1 t2 ->
        nested (text "Matching would result in an infinite type.")
          (text "The type: " <+> ppWithNames names t1 $$
           text "occurs in:" <+> ppWithNames names t2)

      UnexpectedTypeWildCard ->
        nested (text "Wild card types are not allowed in this context")
          (text "(e.g., they cannot be used in type synonyms).")

      KindMismatch k1 k2 ->
        nested (text "Incorrect type form.")
          (text "Expected:" <+> cppKind k1 $$
           text "Inferred:" <+> cppKind k2)

      TooManyTypeParams extra k ->
        nested (text "Malformed type.")
          (text "Kind" <+> quotes (pp k) <+> text "is not a function," $$
           text "but it was applied to" <+> pl extra "parameter" <> text ".")

      TooManyTySynParams t extra ->
        nested (text "Malformed type.")
          (text "Type synonym" <+> nm t <+> text "was applied to" <+>
            pl extra "extra parameter" <> text ".")

      TooFewTySynParams t few ->
        nested (text "Malformed type.")
          (text "Type" <+> nm t <+> text "is missing" <+>
            int few <+> text "parameters.")

      RepeatedTyParams ps ->
        nested (text "Different type parameters use the same name:")
          (vmulti [ nm (P.tpName p) <+>
                    text "defined at" <+> mb (P.tpRange p) | p <- ps ] )
          where mb Nothing  = text "unknown location"
                mb (Just x) = pp x

      RepeatedDefinitions x ps ->
        nested (text "Multiple definitions for the same name:")
          (vmulti [ nm x <+> text "defined at" <+> pp p | p <- ps ])

      RecursiveTypeDecls ts ->
        nested (text "Recursive type declarations:")
               (fsep $ punctuate comma $ map nm ts)

      UndefinedTypeSynonym x ->
        text "Type synonym" <+> nm x <+> text "is not defined."

      UndefinedVariable x ->
        text "Variable" <+> nm x <+> text "was not defined."

      UndefinedTypeParam x ->
        text "Type variable" <+> nm x <+> text "was not defined."

      MultipleTypeParamDefs x ps ->
        nested (text "Multiple definitions for the same type parameter"
                                                        <+> nm x <> text ":")
               (vmulti [ text "defined at" <+> pp p | p <- ps ])


      TypeMismatch t1 t2 ->
        nested (text "Type mismatch:")
          (text "Expected type:" <+> ppWithNames names t1 $$
           text "Inferred type:" <+> ppWithNames names t2 $$
           mismatchHint t1 t2)

      UnsolvedGoals imp gs ->
        nested (word <+> text "constraints:")
               $ vcat $ map (ppWithNames names) gs
        where word = if imp then text "Unsolvable" else text "Unsolved"

      UnsolvedDelayedCt g ->
        nested (text "Failed to validate user-specified signature.")
               (ppWithNames names g)

      TypeVariableEscaped t xs ->
        nested (text "The type" <+> ppWithNames names t <+>
                text "is not sufficiently polymorphic.")
               (text "It cannot depend on quantified variables:" <+>
                sep (punctuate comma (map (ppWithNames names) xs)))

      NotForAll x t ->
        nested (text "Inferred type is not sufficiently polymorphic.")
          (text "Quantified variable:" <+> ppWithNames names x $$
           text "cannot match type:"   <+> ppWithNames names t)

      UnusableFunction f ps ->
        nested (text "The constraints in the type signature of"
                <+> quotes (pp f) <+> text "are unsolvable.")
               (text "Detected while analyzing constraints:"
                $$ vcat (map (ppWithNames names) ps))

      TooManyPositionalTypeParams ->
        text "Too many positional type-parameters in explicit type application"

      CannotMixPositionalAndNamedTypeParams ->
        text "Named and positional type applications may not be mixed."

      AmbiguousType xs ->
        text "The inferred type for" <+> commaSep (map pp xs)
          <+> text "is ambiguous."

    where
    nested x y = x $$ nest 2 y

    pl 1 x     = text "1" <+> text x
    pl n x     = text (show n) <+> text x <> text "s"

    nm x       = text "`" <> pp x <> text "`"

    vmulti          = vcat . multi

    multi []        = []
    multi [x]       = [x <> text "."]
    multi [x,y]     = [x <> text ", and", y <> text "." ]
    multi (x : xs)  = x <> text "," : multi xs

    mismatchHint (TRec fs1) (TRec fs2) =
      hint "Missing" missing $$ hint "Unexpected" extra
      where
        missing = map fst fs1 \\ map fst fs2
        extra   = map fst fs2 \\ map fst fs1
        hint _ []  = mempty
        hint s [x] = text s <+> text "field" <+> pp x
        hint s xs  = text s <+> text "fields" <+> commaSep (map pp xs)
    mismatchHint _ _ = mempty


instance PP ConstraintSource where
  ppPrec _ src =
    case src of
      CtComprehension -> text "list comprehension"
      CtSplitPat      -> text "split (#) pattern"
      CtTypeSig       -> text "type signature"
      CtInst e        -> text "use of" <+> ppUse e
      CtSelector      -> text "use of selector"
      CtExactType     -> text "matching types"
      CtEnumeration   -> text "list enumeration"
      CtDefaulting    -> text "defaulting"
      CtPartialTypeFun f -> text "use of partial type function" <+> pp f
      CtImprovement   -> text "examination of collected goals"
      CtPattern desc  -> text "checking a pattern:" <+> desc

ppUse :: Expr -> Doc
ppUse expr =
  case expr of
    EVar (asPrim -> Just prim)
      | identText prim == "demote"       -> text "literal or demoted expression"
      | identText prim == "infFrom"      -> text "infinite enumeration"
      | identText prim == "infFromThen"  -> text "infinite enumeration (with step)"
      | identText prim == "fromThen"     -> text "finite enumeration"
      | identText prim == "fromTo"       -> text "finite enumeration"
      | identText prim == "fromThenTo"   -> text "finite enumeration"
    _                          -> text "expression" <+> pp expr

instance PP (WithNames Goal) where
  ppPrec _ (WithNames g names) =
      (ppWithNames names (goal g)) $$
               nest 2 (text "arising from" $$
                       pp (goalSource g)   $$
                       text "at" <+> pp (goalRange g))

instance PP (WithNames DelayedCt) where
  ppPrec _ (WithNames d names) =
    sig $$ nest 2 (vars $$ asmps $$ vcat (map (ppWithNames ns1) (dctGoals d)))
    where
    sig = text "In the definition of" <+> quotes (pp name) <>
          comma <+> text "at" <+> pp (nameLoc name) <> colon

    name  = dctSource d
    vars = case dctForall d of
             [] -> empty
             xs -> text "for any type" <+>
                      fsep (punctuate comma (map (ppWithNames ns1 ) xs))
    asmps = case dctAsmps d of
              [] -> empty
              xs -> nest 2 (vcat (map (ppWithNames ns1) xs)) $$ text "=>"

    ns1 = addTNames (dctForall d) names



