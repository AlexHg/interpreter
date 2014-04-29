module Compiler.CPS.Convert where

import Control.Monad (forM)
import Data.Maybe (fromMaybe)

import qualified Compiler.CPS as CPS
import qualified Compiler.Simple as Simple

convert :: Simple.Program -> CPS.Program
convert p = run p $ do
  mapM_ convertSum (Simple.programSums p)
  mapM_ convertFun (Simple.programFuns p)
  d  <- createStartFun (Simple.programMain p)
  x1 <- get programSums
  x2 <- get programFuns
  -- d  <- renameFunIdent (Simple.programMain p)
  return $ CPS.Program x1 x2 d

convertSum :: (Simple.Ident, Simple.Sum) -> M ()
convertSum (d0, Simple.Sum tyss) = do
  tyss' <- mapM (mapM convertType) tyss
  d0' <- renameSumIdent d0
  exportSum (d0', CPS.Sum tyss')

convertFun :: (Simple.Ident, Simple.Fun) -> M ()
convertFun (d0, Simple.Fun ty0 t0) = do
  d1  <- renameFunIdent d0
  d2  <- gen
  d3  <- gen
  t1  <- convertTerm t0 (createH d3) (createK d2)
  ty1 <- convertType ty0
  ty2 <- getHandlerType
  exportFun (d1, CPS.Fun [d2, d3] [CPS.ArrowType [ty1, ty2], ty2] t1)

convertTerm :: Simple.Term -> H -> K -> M CPS.Term
convertTerm t h k =
  case t of
    Simple.ApplyTerm t1 t2 ->
      convertTerm t1 h $ \ h d1 ty1 ->
        convertTerm t2 h $ \ h d2 _ ->
          createKClosure k (arrowTypeResult ty1) $ \ d3 _ ->
            createHClosure h $ \ d4 ->
              return $ CPS.ApplyTerm d1 [d2, d3, d4]
    Simple.BindTerm d1 t2 t3 -> do
      convertTerm t2 h $ \ h d2 ty2 -> do
        bind d1 d2 ty2 $
          convertTerm t3 h k
    Simple.CaseTerm t1 c1s -> do
      convertTerm t1 h $ \ h d1 ty1 -> do
        ty2 <- getRuleType ty1 (head c1s)
        createKClosure k ty2 $ \ d3 _ ->
          createHClosure h $ \ d4 -> do
            c1s' <- mapM (convertRule (createH d4) (createK d3)) c1s
            return $ CPS.CaseTerm d1 c1s'
    Simple.CatchTerm d1 d2 t1 ->
      -- We have to begin here, which handles the catch. I think it should
      -- very nearly simply call the function with h, k, and the result, which
      -- would be easy.
      let h' d3 = do
            -- The type given to K is the stream type.
            createKClosure k (CPS.SumType d2) $ \ d6 _ ->
              createHClosure h $ \ d7 -> do
                ty1 <- getTermType t1
                d8 <- createHandlerFunction d1 ty1 d2
                return $ CPS.CallTerm d8 [d3, d6, d7]
          k' h d3 ty3 = do
            d4  <- gen
            -- This I think could be a normal result to a particular tag, but
            -- I'm not sure we want to do that.
            d5  <- getResultTypeIdent
            i   <- getNormalResultIndex ty3
            t2' <- h d4
            return $ CPS.ConstructorTerm d4 d5 i [d3]
                   $ t2'
       in convertTerm t1 h' k'
    Simple.ConcatenateTerm t1 t2 -> do
      convertTerm t1 h $ \ h d1 ty1 -> do
        convertTerm t2 h $ \ h d2 ty2 -> do
          d3 <- gen
          t3 <- k h d3 CPS.StringType
          return $ CPS.ConcatenateTerm d3 d1 d2 t3
    Simple.ConstructorTerm d1 i t1s -> do -- Ident Index [Term]
      convertTerms t1s h $ \ h d1s ty1s -> do
        d2 <- gen
        t2 <- k h d2 (CPS.TupleType ty1s)
        return $ CPS.TupleTerm d2 d1s t2
    Simple.FunTerm d1 -> do
      d2 <- renameFunIdent d1
      ty1 <- getFunType d1
      createKClosure k ty1 $ \ d3 _ ->
        createHClosure h $ \ d4 -> do
          return $ CPS.CallTerm d2 [d3, d4]
    Simple.LambdaTerm d1 ty1 t1 -> do
      d1' <- gen
      ty1' <- convertType ty1
      bind d1 d1' ty1' $ do
        d2   <- gen
        d3   <- gen
        d4   <- gen
        t1'  <- convertTerm t1 (createH d4) (createK d3)
        ty2' <- getTermType t1
        ty0' <- getHandlerType
        t2'  <- k h d2 (CPS.ArrowType [ty1', CPS.ArrowType [ty2', ty0'], ty0'])
        return $ CPS.LambdaTerm d2 [d1', d3, d4] [ty1', CPS.ArrowType [ty2', ty0'], ty0'] t1' t2'
    Simple.StringTerm s1 -> do
      d1 <- gen
      t1 <- k h d1 CPS.StringType
      return $ CPS.StringTerm d1 s1 t1
    Simple.ThrowTerm d1 t1 ->
      convertTerm t1 h $ \ h d1 ty1 -> do
        ty2 <- getTagResultType d1
        createKClosure k ty2 $ \ d2 _ -> do
          d3 <- gen
          d4 <- getResultTypeIdent
          i <- getThrowIndex d1
          t2 <- h d3
          return $ CPS.ConstructorTerm d3 d4 i [d1, d2]
                 $ t2
    Simple.TupleTerm t1s -> do
      convertTerms t1s h $ \ h d1s ty1s -> do
        d2 <- gen
        t2 <- k h d2 (CPS.TupleType ty1s)
        return $ CPS.TupleTerm d2 d1s t2
    Simple.UnitTerm -> do
      d <- gen
      t <- k h d (CPS.TupleType [])
      return $ CPS.TupleTerm d [] t
    Simple.UnreachableTerm _ -> do
      -- This should not take a type.
      return $ CPS.UnreachableTerm
    Simple.UntupleTerm d1s t1 t2 -> do
      d2s <- mapM (const gen) d1s
      convertTerm t1 h $ \ h d1' ty1 -> do
        CPS.TupleType ty1s <- return ty1
        d1s' <- mapM (const gen) d1s
        binds d1s d1s' ty1s $ do
          t2' <- convertTerm t2 h k
          return $ CPS.UntupleTerm d1s' d1' t2'
    Simple.VariableTerm d1 -> do
      (d2, ty2) <- lookupIdent d1
      k h d2 ty2

convertTerms :: [Simple.Term] -> H -> (H -> [CPS.Ident] -> [CPS.Type] -> M CPS.Term) -> M CPS.Term
convertTerms [] h k = k h [] []
convertTerms (t:ts) h k = do
  convertTerm t h $ \ h d ty -> do
    convertTerms ts h $ \ h ds tys -> do
      k h (d:ds) (ty:tys)

run :: Simple.Program -> M CPS.Program -> CPS.Program
run = undefined

convertType :: Simple.Type -> M CPS.Type
convertType ty =
  case ty of
    Simple.ArrowType ty1 ty2 -> do
      ty0' <- getHandlerType
      ty1' <- convertType ty1
      ty2' <- convertType ty2
      return $ CPS.ArrowType [ty1', CPS.ArrowType [ty2', ty0'], ty0']
    Simple.StringType ->
      return $ CPS.StringType
    Simple.TupleType tys -> do
      tys' <- mapM convertType tys
      return $ CPS.TupleType tys'
    Simple.UnitType ->
      return $ CPS.TupleType []
    Simple.SumType s1 ->
      return $ CPS.SumType s1

getRuleType :: CPS.Type -> ([Simple.Ident], Simple.Term) -> M CPS.Type
getRuleType ty (ds, t) = do
  CPS.SumType d1 <- return ty
  undefined

getTermType :: Simple.Term -> M CPS.Type
getTermType t = undefined

getHandlerType :: M CPS.Type
getHandlerType = do
  d <- getResultTypeIdent
  return $ CPS.ArrowType [CPS.SumType d]

createH :: CPS.Ident -> H
createH d1 d2 = return $ CPS.ApplyTerm d1 [d2]

createK :: CPS.Ident -> K
createK d1 h d2 _ =
  createHClosure h $ \ d3 ->
    return $ CPS.ApplyTerm d1 [d2, d3]

convertRule :: H -> K -> ([Simple.Ident], Simple.Term) -> M ([CPS.Ident], CPS.Term)
convertRule h k (d1s, t1) = do
  t1' <- convertTerm t1 h k
  return (d1s, t1')

-- Eta-reduce the K closure if possibe.
createKClosure :: K -> CPS.Type -> (CPS.Ident -> CPS.Type -> M CPS.Term) -> M CPS.Term
createKClosure k ty1 m = do
  d1 <- gen
  d2 <- gen
  t1 <- k (\ d3 -> return $ CPS.ApplyTerm d2 [d3]) d1 ty1
  ty2 <- getHandlerType
  case t1 of
    CPS.ApplyTerm d3 [d4, d5] | d3 /= d4 && d3 /= d5 && d1 == d4 && d2 == d5 ->
      m d3 (CPS.ArrowType [ty1, ty2])
    _ -> do
      d3 <- gen
      t2 <- m d3 (CPS.ArrowType [ty1, ty2])
      return $ CPS.LambdaTerm d3 [d1, d2] [ty1, ty2] t1 t2

-- Eta-reduce the H closure if possibe.
createHClosure :: H -> (CPS.Ident -> M CPS.Term) -> M CPS.Term
createHClosure h m = do
  d1 <- gen
  t1 <- h d1
  case t1 of
    CPS.ApplyTerm d2 [d3] | d2 /= d3 && d1 == d3 ->
      m d2
    _ -> do
      d2 <- gen
      t2 <- m d2
      d3 <- getResultTypeIdent
      return $ CPS.LambdaTerm d2 [d1] [CPS.SumType d3] t1 t2

arrowTypeResult :: CPS.Type -> CPS.Type
arrowTypeResult (CPS.ArrowType [_, CPS.ArrowType [ty, _], _]) = ty
arrowTypeResult _ = error "arrowTypeResult"

type K = H -> CPS.Ident -> CPS.Type -> M CPS.Term
type H = CPS.Ident -> M CPS.Term

newtype M' b a = M { runM :: State -> Reader -> (a -> State -> b) -> b }

type M a = M' CPS.Program a

instance Monad (M' b) where
  return x = M $ \ s _ k -> k x s
  m >>= f = M $ \ s r k -> runM m s r $ \ x s -> runM (f x) s r k

data Reader = R { resultIdent :: CPS.Ident
                , localBindings :: [(Simple.Ident, (CPS.Ident, CPS.Type))]
                }

data State = S { genInt :: Int
               , programSums :: [(CPS.Ident, CPS.Sum)]
               , programFuns :: [(CPS.Ident, CPS.Fun)]
               , sumIdentRenames :: [(Simple.Ident, CPS.Ident)]
               , funIdentRenames :: [(Simple.Ident, CPS.Ident)]
               }

look :: (Reader -> a) -> M a
look f = M $ \ s r k -> k (f r) s

with :: (Reader -> Reader) -> M a -> M a
with f m = M $ \ s r k -> runM m s (f r) k

get :: (State -> a) -> M a
get f = M $ \ s _ k -> k (f s) s

set :: (State -> State) -> M ()
set f = M $ \ s _ k -> k () (f s)

-- Generates a new ident.
gen :: M CPS.Ident
gen = do
  i <- get genInt
  set (\ s -> s {genInt = i + 1})
  return i

-- Returns the sum type ident for Result.
getResultTypeIdent :: M CPS.Ident
getResultTypeIdent = do
  look resultIdent

getResultType :: M CPS.Type
getResultType = do
  d <- getResultTypeIdent
  return $ CPS.SumType d

bind :: Simple.Ident -> CPS.Ident -> CPS.Type -> M a -> M a
bind d1 d2 ty2 = with (\ r -> r {localBindings = (d1, (d2, ty2)) : localBindings r})

binds :: [Simple.Ident] -> [CPS.Ident] -> [CPS.Type] -> M a -> M a
binds [] [] [] m = m
binds (d1:d1s) (d2:d2s) (ty1:ty1s) m = bind d1 d2 ty1 $ binds d1s d2s ty1s m
binds _ _ _ _ = undefined

lookupIdent :: Simple.Ident -> M (CPS.Ident, CPS.Type)
lookupIdent d = do
  xs <- look localBindings
  return $ fromMaybe (undefined) $ lookup d xs


-- Returns the constructor index for the tag.
getThrowIndex :: Simple.Ident -> M CPS.Index
getThrowIndex d = undefined

-- Note that this is a Simple.Ident and not a CPS.Ident.
getFunType :: Simple.Ident -> M CPS.Type
getFunType = undefined

-- The first set is every possible normal result type. The second set is every
-- possible tag result.
getStandardRules :: M [([CPS.Ident], CPS.Term)]
getStandardRules = undefined

getNormalResultIndex :: CPS.Type -> M CPS.Index
getNormalResultIndex ty = undefined

getTagResultType :: CPS.Ident -> M CPS.Type
getTagResultType d = undefined

makeNormalResult :: CPS.Type -> H -> K -> M ([CPS.Ident], CPS.Term)
makeNormalResult ty1 h k = do
  d1 <- gen
  return ([d1], CPS.UnreachableTerm)

--   sd is the sum ident of the stream which is of the first argument to the
--         continuation closure
createHandlerFunction :: CPS.Ident -> CPS.Type -> CPS.Ident -> M CPS.Ident
createHandlerFunction td ty1 sd = do
  d0 <- gen
  d1 <- gen
  d2 <- gen
  d3 <- gen
  ty2 <- getResultType
  ty3 <- getHandlerType
  c1s <- createRules d0 td ty1 sd d2 d3
  exportFun ( d0
            , CPS.Fun [d1, d2, d3] [ty2, CPS.ArrowType [CPS.SumType sd, ty3], ty3]
            $   CPS.CaseTerm d1 c1s
            )
  return d0

-- A throw picks an index based only on the tag.
--   d0  is the ident of the handler function
--   d1  is the tag being caught
--   ty1 is the type of the body of the catch
--   sd  is the ident of the stream sum used
--   kd  is the ident of the continuation closure
--   hd  is the ident of the handler closure
createRules :: CPS.Ident -> CPS.Ident -> CPS.Type -> CPS.Ident -> CPS.Ident -> CPS.Ident -> M [([CPS.Ident], CPS.Term)]
createRules d0 d1 ty1 sd kd hd = do
  rd <- getResultTypeIdent
  rty <- getResultType
  hty <- getHandlerType
  -- We could just lookup from the tag types.
  (ty2, ty3) <- getTag d1
  sty <- return $ CPS.SumType sd
  xs <- getTagTypes
  xs' <- forM xs $ \ (d2, i1, ty2, ty3) ->
           if d1 == d2
             then do
               d3 <- gen
               d4 <- gen
               d5 <- gen
               d6 <- gen
               d7 <- gen
               d8 <- gen
               d9 <- gen
               d10 <- gen
               d11 <- gen
               return ( [d3, d4]
                      , CPS.LambdaTerm d5 [d6, d7, d8] [ty3, CPS.ArrowType [sty, hty], hty]
                          ( CPS.LambdaTerm d9 [d10] [rty]
                             ( CPS.CallTerm d0 [d10, d7, d8])
                          $ CPS.ApplyTerm d4 [d6, d9]
                          )
                      $ CPS.ConstructorTerm d11 sd 1 [d3, d5]
                      $ CPS.ApplyTerm kd [d11, hd]
                      )
             else do
               d3 <- gen
               d4 <- gen
               d5 <- gen
               d6 <- gen
               d7 <- gen
               d8 <- gen
               d9 <- gen
               d10 <- gen
               return ( [d3, d4]
                      , CPS.LambdaTerm d5 [d6, d7] [ty3, hty]
                          ( CPS.LambdaTerm d8 [d9] [rty]
                              (CPS.CallTerm d0 [d9, kd, d7])
                          $ CPS.ApplyTerm d4 [d6, d8]
                          )
                      $ CPS.ConstructorTerm d10 rd i1 [d3, d5]
                      $ CPS.ApplyTerm hd [d10]
                      )
  ys <- getNormalTypes
  ys' <- forM ys $ \ ty2 ->
           if CPS.SumType sd == ty2
             then do
               d3 <- gen
               d4 <- gen
               return ( [d3]
                      , CPS.ConstructorTerm d4 sd 0 [d3]
                      $ CPS.ApplyTerm kd [d4, hd]
                      )
             else do
               d3 <- gen
               return ( [d3]
                      , CPS.UnreachableTerm
                      )
  return $ xs' ++ ys'

getStreamTypeIdent :: CPS.Type -> CPS.Type -> CPS.Type -> M CPS.Ident
getStreamTypeIdent ty1 ty2 ty3 = undefined

getTag :: CPS.Ident -> M (CPS.Type, CPS.Type)
getTag d1 = undefined

getTagTypes :: M [(CPS.Ident, CPS.Index, CPS.Type, CPS.Type)]
getTagTypes = undefined

getNormalTypes :: M [CPS.Type]
getNormalTypes = undefined

createStartFun :: Simple.Ident -> M CPS.Ident
createStartFun d1 = do
  d2 <- gen
  d3 <- gen
  d4 <- gen
  d5 <- gen
  d6 <- gen
  d7 <- gen
  d8 <- gen
  d9 <- gen
  ty1 <- convertType (Simple.SumType 0)
  i   <- getNormalResultIndex ty1
  ty2 <- getHandlerType
  ty3 <- getResultType
  exportFun (d2
            , CPS.Fun [] []
              -- This is called with the Output type. It should pass it on to the handler.
            $ CPS.LambdaTerm d3 [d4, d5] [ty1, ty2]
                ( CPS.ConstructorTerm d6 d7 i [d4]
                $ CPS.ApplyTerm d5 [d6]
                )
                -- This is called with the Result type.
            $   CPS.LambdaTerm d8 [d9] [ty3]
                  CPS.UnreachableTerm
            $   CPS.CallTerm d1 [d3, d8]
            )
  return d2

renameSumIdent :: Simple.Ident -> M CPS.Ident
renameSumIdent d = do
  xs <- get sumIdentRenames
  case lookup d xs of
    Nothing -> do
      d' <- gen
      set $ \ s -> s {sumIdentRenames = (d,d'):xs}
      return d'
    Just d' ->
      return d'

renameFunIdent :: Simple.Ident -> M CPS.Ident
renameFunIdent d = do
  xs <- get funIdentRenames
  case lookup d xs of
    Nothing -> do
      d' <- gen
      set $ \ s -> s {funIdentRenames = (d,d'):xs}
      return d'
    Just d' ->
      return d'

exportSum :: (CPS.Ident, CPS.Sum) -> M ()
exportSum x = do
  xs <- get programSums
  set $ \ s -> s {programSums = x:xs}

exportFun :: (CPS.Ident, CPS.Fun) -> M ()
exportFun x = do
  xs <- get programFuns
  set $ \ s -> s {programFuns = x:xs}

-- Utility Functions

substitute :: Int -> a -> [a] -> [a]
substitute 0 x (_ : ys) = x : ys
substitute n x (y : ys) = y : substitute (n-1) x ys
substitute n x []       = error "substitute out of bounds"
