module Compiler.Syntax where

import qualified Compiler.Type as Type

data Program = Program [Dec]
               deriving (Eq, Show)

type Ident = String

data Dec = FunDec Pos String [String] [Pat] Typ Term
      -- | SumDec Pos String [String] [(Pos, String, [Pat])]
      -- | TagDec Pos String Typ
           deriving (Eq, Show)

data Term = ApplyTerm Type.Type Term Term
          | AscribeTerm Pos Term Typ
          | BindTerm Type.Type Pat Term Term
       -- | CaseTerm Term [(Pat, Term)]
          | SeqTerm Term Term
          | TupleTerm Pos [Type.Type] [Term]
          | UnitTerm Pos
          | UpperTerm Pos [Type.Type] Type.Type String
          | VariableTerm Pos String
            deriving (Eq, Show)

data Pat = AscribePat Pat Typ
         | LowerPat String
         | TuplePat [Type.Type] [Pat]
         | UnderbarPat
         | UnitPat Pos
      -- | UpperPat String [Pat]
           deriving (Eq, Show)

data Typ = ArrowTyp Typ Typ
         | LowerTyp String
         | TupleTyp [Typ]
         | UnitTyp Pos
         | UpperTyp Pos String -- [Typ]
           deriving (Eq, Show)

-- | Position filename line col.

data Pos = Pos String Int Int
           deriving (Eq, Show)

funType :: [Pat] -> Typ -> Type.Type
funType []     t = typType t
funType (p:ps) t = Type.Arrow (patType p) (funType ps t)

patType :: Pat -> Type.Type
patType (AscribePat p ty) = typType ty -- not sure about this
patType (LowerPat s)      = error "Compiler.Syntax.patType"
patType (TuplePat _ ps)   = Type.Tuple (map patType ps)
patType UnderbarPat       = error "Compiler.Syntax.patType"
patType (UnitPat _)       = Type.Unit

typType :: Typ -> Type.Type
typType (ArrowTyp ty1 ty2) = Type.Arrow (typType ty1) (typType ty2)
typType (LowerTyp s)       = Type.Variable s
typType (TupleTyp tys)     = Type.Tuple (map typType tys)
typType (UnitTyp _)        = Type.Unit
typType (UpperTyp _ s)     = Type.Variant s []
