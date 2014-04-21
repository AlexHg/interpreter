module Compiler.CPS where

type Ident = Int
type Index = Int

data Program = Program
 { programSums :: [(Ident, Sum)]
 , programFuns :: [(Ident, Fun)]
 , programMain :: Ident
 } deriving (Eq, Ord, Show)

data Sum = Sum [[Type]]
   deriving (Eq, Ord, Show)

data Fun = Fun [Ident] [Type] Term
   deriving (Eq, Ord, Show)

data Type =
   ArrowType [Type]
 | StringType
 | TupleType [Type]
 | UnitType
 | SumType Ident
   deriving (Eq, Ord, Show)

data Term =
   ApplyTerm Ident [Ident]
 | CallTerm Ident [Ident]
 | CaseTerm Ident [([Ident], Term)]
 | ConcatenateTerm Ident Ident Ident Term
 | ConstructorTerm Ident Ident Index [Ident] Term
 | LambdaTerm Ident [Ident] [Type] Term Term
 | StringTerm Ident String Term
 | TupleTerm Ident [Ident] Term
 | UnreachableTerm Type
 | UntupleTerm [Ident] Term Term
   deriving (Eq, Ord, Show)
