{-# OPTIONS_GHC -Wno-missing-signatures #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}

module TCSubtyping where

import Control.Applicative
import Control.Monad (ap)
import Data.List (nub, sort)
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Config as D

import Syntax
import PrettySyntax
import Kinds
import qualified TCXMonad as TC

type Cache = [(Type, Type)]

data Caches = Caches { subCache :: Cache, eqvCache :: Cache }
     deriving Show

type TCM a = TC.M KEnv Caches [Constraint] a

mlookup :: (Monoid w, Eq ident, Show ident) => ident -> TC.M [(ident, bind)] s w bind
mlookup tname = do
  tnames <- TC.mget
  case lookup tname tnames of
    Nothing ->
      TC.mfail ("No type binding for " ++ show tname)
    Just tb ->
      pure tb

initCaches :: Caches
initCaches = Caches [] []

eqvCacheLookup :: Monoid w => (Type, Type) -> TC.M r Caches w Bool
eqvCacheLookup centry = do
  caches <- TC.mupdate (\cs -> cs { eqvCache = centry : eqvCache cs })
  return (centry `elem` eqvCache caches)

subCacheLookup :: Monoid w => (Type, Type) -> TC.M r Caches w Bool
subCacheLookup centry = do
  caches <- TC.mupdate (\cs -> cs { subCache = centry : subCache cs })
  return (centry `elem` subCache caches)
  -- could also check in eqvCache!

-- value equivalence
valueEquiv' :: TEnv -> Exp -> Maybe (Exp, Type)
valueEquiv' tenv (Lit (LLab name)) = Just (Lit $ LLab name, TLab [name])
valueEquiv' tenv (Lit (LNat v)) = Just (Lit $ LNat v, TNat)
valueEquiv' tenv (Var name) =
  -- consider only relevant equation after last binding for name
  let relevantTenv = takeWhile ((/= name) . fst) tenv
      eqnEnv = [ (name, (val, ty))
               | (_, (Many, TEqn (Var name) val ty)) <- relevantTenv] in
  do (e, t) <- lookup name eqnEnv
     case e of
       Lit (LLab _) -> return (e, t)
       Lit (LNat _) -> return (e, t)
       Succ _ -> return (e, t)
       Var x -> valueEquiv tenv e
  <|>
  do (_, TSingle y) <- lookup name tenv
     valueEquiv tenv (Var y)
valueEquiv' tenv _ =
  Nothing

valueEquiv :: TEnv -> Exp -> Maybe (Exp, Type)
valueEquiv tenv exp =
  let r = valueEquiv' tenv exp in
    D.trace ("valueEquiv " ++ pshow tenv ++ " " ++ pshow exp ++ " = " ++ pshow r) r

lablookup :: Monoid w => String -> [(String, Type)] -> TC.M r s w Type
lablookup lll cases =
  maybe (TC.mfail ("No case for label " ++ show lll)) return $
  lookup lll cases

varlookup x tenv =
  maybe (TC.mfail ("No binding for variable " ++ show x)) return $
  lookup x tenv

-- extended lookup returns remaining tenv and the binding
varlookup' x [] =
  TC.mfail ("No binding for variable " ++ show x)
varlookup' x ((y,e):tenv)
  | x == y = return (tenv, e)
  | otherwise = varlookup' x tenv

-- lookup and unfold type
varlookupUnfolding x tenv = do
  (tenvx, (_, tyx)) <- varlookup' x tenv
  unfold tenvx tyx

varlookupLabel x tenv = do
  lty <- varlookupUnfolding x tenv
  case lty of
    TLab labs ->
      return (lty, labs)
    _ ->
      TC.mfail ("Label type expected, got " ++ pshow lty)

varlookupNat x tenv = do
  lty <- varlookupUnfolding x tenv
  case lty of
    TNat ->
      return ()
    _ ->
      TC.mfail ("Label type expected, got " ++ pshow lty)

-- expose top-level type constructor
unfold :: TEnv -> Type -> TCM Type
unfold tenv (TName b tn) = do
  kentry <- mlookup tn
  unfold tenv $ cdualof b $ keType kentry -- was: return $
unfold tenv (TCase val cases)
  | Just (Lit (LLab lll), TLab _) <- valueEquiv tenv val = do
      ty <- lablookup lll cases
      unfold tenv ty
unfold tenv t0@(TCase val@(Var x) cases) = do
  let caselabels = map fst cases
  tyx <- varlookupUnfolding x tenv
  results <- case tyx of
    TLab labs ->
      mapM (\lll -> lablookup lll cases >>=
                    unfold (("*unfold*", (Many, TEqn val (Lit $ LLab lll) tyx)) : tenv))
            labs
    TDyn ->
      mapM (\(lll, tyl) -> unfold (("*unfold*", (Many, TEqn val (Lit $ LLab lll) tyx)) : tenv) tyl) cases
    _ ->
      TC.mfail ("unfold: header was neither dynamic nor label type - " ++ pshow tyx)

  case commonGrounds results of
    Just (GFun m) -> do
      let xarg = freshvar x (fv t0) -- fill this
          farg (TFun _ z targ tres) = targ
          farg TDyn = TDyn
          fres (TFun _ z targ tres) = subst z (Var xarg) tres
          fres TDyn = TDyn
          targcases = zip caselabels $ map farg results
          trescases = zip caselabels $ map fres results
      return $ TFun m xarg (TCase val targcases) (TCase val trescases)
    Just (GPair m) -> do
      let xarg = freshvar x (fv t0) -- fill this
          farg (TPair _ z targ tres) = targ
          farg TDyn = TDyn
          fres (TPair _ z targ tres) = subst z (Var xarg) tres
          fres TDyn = TDyn
          targcases = zip caselabels $ map farg results
          trescases = zip caselabels $ map fres results
      return $ TPair m xarg (TCase val targcases) (TCase val trescases)
    Just GDyn -> do
      return TDyn           -- all cases dynamic - eta reduce the case
    _ ->
      TC.mfail "unfold dynamic: type mismatch"

unfold tenv (TNatRec e1 tz1 tv1 ts1)
  | Just (v, TNat) <- valueEquiv tenv e1 =
      case v of
        Lit (LNat 0) ->
          unfold tenv tz1
        Lit (LNat n) | n > 0 ->
          unfold tenv (tsubst tv1 (TNatRec (Lit $ LNat (n-1)) tz1 tv1 ts1) ts1)
        Succ var ->
          unfold tenv (tsubst tv1 (TNatRec var tz1 tv1 ts1) ts1)
        _ ->
          TC.mfail "eqvtype: type mismatch"
unfold tenv ty =
  return ty

data GHead = GDyn | GLab | GUnit | GInt | GNat | GDouble | GString | GFun Multiplicity | GPair Multiplicity | GSend | GRecv
  deriving (Eq)

commonGround :: Type -> Maybe GHead
commonGround TUnit = Just GUnit
commonGround TInt = Just GInt
commonGround TDouble = Just GDouble
commonGround TString = Just GString
commonGround TBot = Nothing
commonGround TDyn = Just GDyn
commonGround TNat = Just GNat
commonGround (TNatRec  _ _ _ _) = Nothing
commonGround (TNatLeq _) = Nothing
commonGround (TVar _ _ ) = Nothing
commonGround (TAbs _ _ _) = Nothing
commonGround (TName _ _) = Nothing
commonGround (TLab _) = Just GLab
commonGround (TFun m _ _ _) = Just (GFun m)
commonGround (TPair m _ _ _) = Just (GPair m)
commonGround (TSend _ _ _) = Just GSend
commonGround (TRecv _ _ _) = Just GRecv
commonGround (TCase _ _ ) = Nothing
commonGround (TEqn _ _ _) = Nothing
commonGround (TSingle _) = Nothing

commonGrounds :: [Type] -> Maybe GHead
commonGrounds [t] = commonGround t
commonGrounds (t:ts) = lubGround (commonGround t) (commonGrounds ts)

combineGround :: GHead -> GHead -> Maybe GHead
combineGround GDyn g2 = Just g2
combineGround g1 GDyn = Just g1
combineGround g1 g2 = if g1 == g2 then Just g1 else Nothing

lubGround :: Maybe GHead -> Maybe GHead -> Maybe GHead
lubGround (Just g1) (Just g2) = combineGround g1 g2
lubGround _ _ = Nothing

-- TODO: need two caches, one for subtyping and one for equivalence
-- type equivalence
eqvtype' :: TEnv -> Type -> Type -> TCM Kind
eqvtype' tenv ty1 ty2@(TName b tn) = do
  kentry <- mlookup tn
  let ty2 = cdualof b $ keType kentry
  let ki2 = keKind kentry
  let centry = (ty1, ty2)
  incache <- eqvCacheLookup centry
  if incache then
    return ki2
    else
    eqvtype tenv ty1 ty2
eqvtype' tenv (TName b tn) ty2 = do
  kentry <- mlookup tn
  let ty1 = cdualof b $ keType kentry
  eqvtype tenv ty1 ty2
eqvtype' tenv TDyn _ = return Kunit
eqvtype' tenv _ TDyn = return Kunit
eqvtype' tenv TUnit TUnit = return Kunit
eqvtype' tenv TInt TInt = return Kunit
eqvtype' tenv TDouble TDouble = return Kunit
eqvtype' tenv TString TString = return Kunit
eqvtype' tenv TNat TNat = return Kunit
eqvtype' tenv (TLab ls1) (TLab ls2) | sort ls1 == sort ls2 = return Kidx
eqvtype' tenv s@(TFun sm sx sin sout) t@(TFun tm tx tin tout) =
  let nx = "zz" ++ show (length tenv) in
  do kin <- eqvtype tenv tin sin
     kout <- eqvtype ((nx, (demote (mult kin), tin)) : tenv)
                     (subst sx (Var nx) sout)
                     (subst tx (Var nx) tout)
     if sm == tm then return $ kindof tm else TC.mfail (pshow s ++ " <: " ++ pshow t)
eqvtype' tenv s@(TPair sm sx sin sout) t@(TPair tm tx tin tout) =
  let nx = "zz" ++ show (length tenv) in
  do kin <- eqvtype tenv sin tin
     kout <- eqvtype ((nx, (demote (mult kin), sin)) : tenv)
                     (subst sx (Var nx) sout)
                     (subst tx (Var nx) tout)
     if sm == tm then return $ kindof tm else TC.mfail (pshow s ++ " <: " ++ pshow t)
eqvtype' tenv (TSend sx sin sout) (TSend tx tin tout) =
  let nx = "zz" ++ show (length tenv) in
  do kin <- eqvtype tenv tin sin
     kout <- eqvtype ((nx, (demote (mult kin), tin)) : tenv)
                     (subst sx (Var nx) sout)
                     (subst tx (Var nx) tout)
     return Kssn
eqvtype' tenv (TRecv sx sin sout) (TRecv tx tin tout) =
  let nx = "zz" ++ show (length tenv) in
  do kin <- eqvtype tenv sin tin
     kout <- eqvtype ((nx, (demote (mult kin), sin)) : tenv)
                     (subst sx (Var nx) sout)
                     (subst tx (Var nx) tout)
     return Kssn
eqvtype' tenv (TCase val cases) ty2
  | Just (Lit (LLab lll), TLab _) <- valueEquiv tenv val =
  do ty1 <- lablookup lll cases
     eqvtype tenv ty1 ty2
eqvtype' tenv (TCase val@(Var x) cases) ty2 =
  do (lty, labs) <- varlookupLabel x tenv
     results <- mapM (\lll -> lablookup lll cases >>= \ty1 ->
                         eqvtype (("*lft*", (Many, TEqn val (Lit $ LLab lll) lty)) : tenv) ty1 ty2)
                labs
     return $ foldr1 klub results
eqvtype' tenv ty1 (TCase val cases)
  | Just (Lit (LLab lll), TLab _) <- valueEquiv tenv val =
  do ty2 <- lablookup lll cases
     eqvtype tenv ty1 ty2
eqvtype' tenv ty1 (TCase val@(Var x) cases) =
  do (lty, labs) <- varlookupLabel x tenv
     results <- mapM (\lll -> lablookup lll cases >>= \ty2 ->
                         eqvtype (("*rgt*", (Many, TEqn val (Lit $ LLab lll) lty)) : tenv) ty1 ty2)
                labs
     return $ foldr1 klub results

-- workzone
eqvtype' tenv ty1@(TNatRec e1 tz1 tv1 ts1) ty2
  | Just (v, TNat) <- valueEquiv tenv e1 =
      case v of
        Lit (LNat 0) ->
          eqvtype tenv tz1 ty2
        Lit (LNat n) | n > 0 ->
          eqvtype tenv (tsubst tv1 (TNatRec (Lit $ LNat (n-1)) tz1 tv1 ts1) ts1) ty2
        Succ var ->
          eqvtype tenv (tsubst tv1 (TNatRec var tz1 tv1 ts1) ts1) ty2
        _ ->
          TC.mfail ("eqvtype: type mismatch")
  -- need to do something about tv1: unfolding should be ok as we have a constant

eqvtype' tenv ty1@(TNatRec val@(Var n) tz1 tv1 ts1) ty2 =
  do varlookupNat n tenv
     let n' = freshvar n (fv ty1)
     eqvtype (("*nlft*", (Many, TEqn val (Lit $ LNat 0) TNat)) : tenv) tz1 ty2
     eqvtype (("*nlft*", (Many, TEqn val (Succ (Var n')) TNat)) :
              (n', (Many, TNat)): tenv)
       (tsubst tv1 (TNatRec (Var n') tz1 tv1 ts1) ts1)
       ty2
     -- seriously need to do something about tv1 in ts1
     -- unfolding may lead to nontermination

eqvtype' tenv ty1 ty2@(TNatRec e tz tv ts)
  | Just (v, TNat) <- valueEquiv tenv e =
      case v of
        Lit (LNat 0) ->
          eqvtype tenv ty1 tz
        Lit (LNat n) | n > 0 ->
          eqvtype tenv ty1 (tsubst tv (TNatRec (Lit $ LNat (n-1)) tz tv ts) ts)
        Succ var -> do
          let ty2'= tsubst tv (TNatRec var tz tv ts) ts
              ty1c = complete (fv ty1) tenv ty1
              ty2c = complete (fv ty2') tenv ty2'
              centry = (ty1c, ty2c)
          incache <- eqvCacheLookup centry
          if incache then
            return Kunit        -- TODO!! unhack
            else
            eqvtype tenv ty1 ty2  -- need to do something about tv1: unfolding should be ok as we have a constant

eqvtype' tenv ty1 ty2@(TNatRec val@(Var n) tz tv ts) =
  do varlookupNat n tenv
     let n' = freshvar n (fv ty2)
         tenv' = (("*nrgt*", (Many, TEqn val (Succ (Var n')) TNat)) :
                  (n', (Many, TNat)):
                  tenv)
         ty2' = (tsubst tv (TNatRec (Var n') tz tv ts) ts)
         ty1c = complete (fv ty1) tenv ty1
         ty2c = complete (fv ty2') tenv ty2'
         centry = (ty1c, ty2c)
     eqvtype (("*nrgt*", (Many, TEqn val (Lit $ LNat 0) TNat)) : tenv) ty1 tz
     incache <- eqvCacheLookup centry
     if incache then
       return Kunit             -- TODO!! unhack
       else
       eqvtype tenv' ty1 ty2'
     -- seriously need to do something about tv in ts
     -- unfolding may lead to nontermination

-- catchall
eqvtype' tenv t1 t2 = TC.mfail ("Fails to establish " ++ pshow t1 ++ " ==: " ++ pshow t2)

eqvtype tenv t1 t2 = do
  r <- eqvtype' tenv t1 t2
  return $ D.trace ("eqvtype " ++ pshow tenv ++ " (" ++ pshow t1 ++ ") (" ++ pshow t2 ++ ") = " ++ show r) r

-- close a type wrt typing environment
complete :: Set Ident -> TEnv -> Type -> Type
complete xs tenv ty | Set.null xs = ty
complete xs ((x, (_, tx)) : tenv) ty =
  if x `elem` xs
  then complete (Set.delete x xs) tenv (TAbs x tx ty)
  else complete xs tenv ty
complete xs [] ty =
  error ("complete failed on " ++ pshow ty)

-- subtyping
subtype' :: TEnv -> Type -> Type -> TCM Kind
subtype' tenv ty1 ty2@(TVar b tv) = do
  kentry <- mlookup tv
  D.traceM ("Subtype constraint: " ++ pshow ty1 ++ " <: " ++ pshow ty2)
  TC.tell [ty1 :<: ty2]
  return (keKind kentry)
subtype' tenv ty1@(TVar b tv) ty2 = do
  kentry <- mlookup tv
  D.traceM ("Subtype constraint: " ++ pshow ty1 ++ " <: " ++ pshow ty2)
  TC.tell [ty1 :<: ty2]
  return (keKind kentry)
subtype' tenv TDyn _ = return Kunit
subtype' tenv _ TDyn = return Kunit
subtype' tenv TUnit TUnit = return Kunit
subtype' tenv TInt TInt = return Kunit
subtype' tenv TDouble TDouble = return Kunit
subtype' tenv TString TString = return Kunit
subtype' tenv TNat TNat = return Kunit
subtype' tenv TNat TInt = return Kunit
subtype' tenv (TLab ls1) (TLab ls2) | all (`elem` ls2) ls1 = return Kidx
subtype' tenv s@(TFun sm sx sin sout) t@(TFun tm tx tin tout) =
  let nx = "zz" ++ show (length tenv) in
  do kin <- subtype tenv tin sin
     kout <- subtype ((nx, (demote (mult kin), tin)) : tenv)
                     (subst sx (Var nx) sout)
                     (subst tx (Var nx) tout)
     if sm <= tm then return $ kindof tm else TC.mfail (pshow s ++ " <: " ++ pshow t)
subtype' tenv s@(TPair sm sx sin sout) t@(TPair tm tx tin tout) =
  let nx = "zz" ++ show (length tenv) in
  do kin <- subtype tenv sin tin
     kout <- subtype ((nx, (demote (mult kin), sin)) : tenv)
                     (subst sx (Var nx) sout)
                     (subst tx (Var nx) tout)
     if sm <= tm then return $ kindof tm else TC.mfail (pshow s ++ " <: " ++ pshow t)
subtype' tenv (TSend sx sin sout) (TSend tx tin tout) =
  let nx = "zz" ++ show (length tenv) in
  do kin <- subtype tenv tin sin
     kout <- subtype ((nx, (demote (mult kin), tin)) : tenv)
                     (subst sx (Var nx) sout)
                     (subst tx (Var nx) tout)
     return Kssn
subtype' tenv (TRecv sx sin sout) (TRecv tx tin tout) =
  let nx = "zz" ++ show (length tenv) in
  do kin <- subtype tenv sin tin
     kout <- subtype ((nx, (demote (mult kin), sin)) : tenv)
                     (subst sx (Var nx) sout)
                     (subst tx (Var nx) tout)
     return Kssn

-- resolve type identifiers (TName) before actual subtyping
subtype' tenv (TCase (Cast x (TName _ tv1) (TName _ tv2)) cases) tyy2 = do
  (t1,_) <- mlookup tv1
  (t2,_) <- mlookup tv2
  subtype tenv (TCase (Cast x t1 t2) cases) tyy2
subtype' tenv (TCase (Cast x (TName _ tv) t2) cases) tyy2 =
  mlookup tv >>= \(t1,_) -> subtype tenv (TCase (Cast x t1 t2) cases) tyy2
subtype' tenv (TCase (Cast x t1 (TName _ tv)) cases) tyy2 =
  mlookup tv >>= \(t2,_) -> subtype tenv (TCase (Cast x t1 t2) cases) tyy2
-- subtyping for casts with case on the left side: case (x:D=>L) {...} <: B
subtype' tenv (TCase (Cast (Var x) t1 (TLab ls2)) cases) tyy2 =
  case lookup x tenv of
    Just (_,TLab [l]) -> do
      t <- lablookup l cases
      subtype tenv t tyy2
    _ -> do
      let ls' = case t1 of
            TDyn    -> ls2
            TLab ls -> filter (`elem` ls) ls2
            _       -> []
          subtypeCast l = do
            let tenv' = (x,(Many,TLab [l])) : tenv
            cty <- lablookup l cases
            subtype tenv' cty tyy2
      results <- mapM subtypeCast ls'
      return $ foldr1 klub results

-- resolve type identifiers (TName) before actual subtyping
subtype' tenv tyy1 (TCase (Cast x (TName _ tv1) (TName _ tv2)) cases) = do
  (t1,_) <- mlookup tv1
  (t2,_) <- mlookup tv2
  subtype tenv tyy1 (TCase (Cast x t1 t2) cases)
subtype' tenv tyy1 (TCase (Cast x (TName _ tv) t2) cases) =
  mlookup tv >>= \(t1,_) -> subtype tenv tyy1 (TCase (Cast x t1 t2) cases)
subtype' tenv tyy1 (TCase (Cast x t1 (TName _ tv)) cases) =
  mlookup tv >>= \(t2,_) -> subtype tenv tyy1 (TCase (Cast x t1 t2) cases)
-- subtyping for casts with case on the right side: A <: case (x:D=>L) {...}
subtype' tenv tyy1 (TCase (Cast (Var x) t1 (TLab ls2)) cases) =
  case lookup x tenv of
    Just (_,TLab [l]) -> do
      t <- lablookup l cases
      subtype tenv tyy1 t
    _ -> do
      let ls' = case t1 of
            TDyn    -> ls2
            TLab ls -> filter (`elem` ls) ls2
            _       -> []
          subtypeCast l = do
            let tenv' = (x,(Many,TLab [l])) : tenv
            cty <- lablookup l cases
            subtype tenv' tyy1 cty
      results <- mapM subtypeCast ls'
      return $ foldr1 klub results

subtype' tenv (TCase val cases) ty2
  | Just (Lit (LLab lll), TLab _) <- valueEquiv tenv val =
  do ty1 <- lablookup lll cases
     subtype tenv ty1 ty2
subtype' tenv (TCase val@(Var x) cases) ty2 =
  do (lty, labs) <- varlookupLabel x tenv
     results <- mapM (\lll -> lablookup lll cases >>= \ty1 ->
                              subtype (("*lft*", (Many, TEqn val (Lit $ LLab lll) lty)) : tenv) ty1 ty2)
                     labs
     return $ foldr1 klub results

subtype' tenv ty1 (TCase val cases)
  | Just (Lit (LLab lll), TLab _) <- valueEquiv tenv val =
  do ty2 <- lablookup lll cases
     subtype tenv ty1 ty2
subtype' tenv ty1 (TCase val@(Var x) cases) =
  do (lty, labs) <- varlookupLabel x tenv
     results <- mapM (\lll -> lablookup lll cases >>= \ty2 ->
                              subtype (("*rgt*", (Many, TEqn val (Lit $ LLab lll) lty)) : tenv) ty1 ty2)
                     labs
     return $ foldr1 klub results

-- workzone
subtype' tenv ty1@(TNatRec e1 tz1 tv1 ts1) ty2
  | Just (v, TNat) <- valueEquiv tenv e1 =
      case v of
        Lit (LNat 0)  ->
          subtype tenv tz1 ty2
        Lit (LNat n)  ->
          subtype tenv (tsubst tv1 (TNatRec (Lit $ LNat (n-1)) tz1 tv1 ts1) ts1) ty2
        Succ var ->
          subtype tenv (tsubst tv1 (TNatRec var tz1 tv1 ts1) ts1) ty2
        _ ->
          TC.mfail ("subtype: type mismatch")
  -- need to do something about tv1: unfolding should be ok as we have a constant

subtype' tenv ty1@(TNatRec val@(Var n) tz1 tv1 ts1) ty2 =
  do varlookupNat n tenv
     let n' = freshvar n (fv ty1)
     subtype (("*nlft*", (Many, TEqn val (Lit $ LNat 0) TNat)) : tenv) tz1 ty2
     subtype (("*nlft*", (Many, TEqn val (Succ (Var n')) TNat)) :
              (n', (Many, TNat)): tenv)
       (tsubst tv1 (TNatRec (Var n') tz1 tv1 ts1) ts1)
       ty2
     -- seriously need to do something about tv1 in ts1
     -- unfolding may lead to nontermination

subtype' tenv ty1 ty2@(TNatRec e tz tv ts)
  | Just (v, TNat) <- valueEquiv tenv e =
      case v of
        Lit (LNat 0) ->
          subtype tenv ty1 tz
        Lit (LNat n) ->
          subtype tenv ty1 (tsubst tv (TNatRec (Lit $ LNat (n-1)) tz tv ts) ts)
        Succ var -> do
          let ty2'= tsubst tv (TNatRec var tz tv ts) ts
              ty1c = complete (fv ty1) tenv ty1
              ty2c = complete (fv ty2') tenv ty2'
              centry = (ty1c, ty2c)
          incache <- subCacheLookup centry
          if incache then
            return Kunit        -- TODO!! unhack
            else
            subtype tenv ty1 ty2'
  -- need to do something about tv1: unfolding should be ok as we have a constant

subtype' tenv ty1 ty2@(TNatRec val@(Var n) tz tv ts) =
  do varlookupNat n tenv
     let n' = freshvar n (fv ty2)
         tenv' = (("*nrgt*", (Many, TEqn val (Succ (Var n')) TNat)) :
                  (n', (Many, TNat)):
                  tenv)
         ty2' = (tsubst tv (TNatRec (Var n') tz tv ts) ts)
         ty1c = complete (fv ty1) tenv ty1
         ty2c = complete (fv ty2') tenv ty2'
         centry = (ty1c, ty2c)
     subtype (("*nrgt*", (Many, TEqn val (Lit $ LNat 0) TNat)) : tenv) ty1 tz
     incache <- subCacheLookup centry
     if incache then
       return Kunit             -- TODO!! unhack
       else
       subtype tenv' ty1 ty2'
     -- seriously need to do something about tv in ts
     -- unfolding may lead to nontermination

subtype' tenv ty1 ty2@(TName b tn) = do
  kentry <- mlookup tn
  let ty2 = cdualof b $ keType kentry
  let ki2 = keKind kentry
  let centry = (ty1, ty2)
  incache <- subCacheLookup centry
  if incache then
    return ki2
    else
    subtype tenv ty1 ty2
subtype' tenv (TName b tn) ty2 = do
  kentry <- mlookup tn
  let ty1 = cdualof b $ keType kentry
  subtype tenv ty1 ty2

subtype' tenv ty1@(TSingle z1) ty2 = do
  (oc1, ty1') <- varlookup z1 tenv
  let k1 = Kun -- (k1, mul1) <- kiSynth tenv ty1'
  case ty2 of
    TSingle z2 ->
      if z1 == z2
      then return k1
      else TC.mfail ("Subtyping fails to establish " ++ pshow ty1 ++ " <: " ++ pshow ty2)
    _ ->
      subtype' tenv ty1' ty2

-- catchall
subtype' tenv t1 t2 = TC.mfail ("Subtyping fails to establish " ++ pshow t1 ++ " <: " ++ pshow t2)

subtype tenv t1 t2 = do
  D.traceM ("Entering subtype " ++ pshow tenv ++ " (" ++ pshow t1 ++ ") (" ++ pshow t2 ++ ")")
  r <- subtype' tenv t1 t2
  return $ D.trace ("subtype " ++ pshow tenv ++ " (" ++ pshow t1 ++ ") (" ++ pshow t2 ++ ") = " ++ show r) r

-- smart constructor that drops the case if all branches are equal (eta reduction)
tcase :: Exp -> Type -> [(String, Type)] -> Type
tcase e tye ((_, t) : cases)
  | all ((==t).snd) cases = t
tcase e tye cases
  | Just (e', seg, tys) <- commonHead e tye cases = segFun seg $ tcase e' tye (zip (map fst cases) tys)
tcase e tye sts = TCase e sts

-- same beast, but checks branch types for equivalence
tcaseM :: TEnv -> Exp -> Type -> [(String, Type)] -> TCM Type
tcaseM te e tye allcases@((_, t) : cases) =
  ap (return (\t -> D.trace ("tcaseM returns " ++ pshow t) t)) $
  D.trace ("tcaseM " ++ pshow (te, e, allcases)) $ (do
  mapM (eqvtype te t . snd) cases -- if all succeed, we are good and we can drop the case
  return t)
 <|> (case commonHead e tye allcases of
       Just (e', seg, tys) ->
         return $ segFun seg $ TCase e' (zip (map fst allcases) tys)
       Nothing -> return $ TCase e allcases)

-- is it a good idea to have this in the Maybe monad?
commonHead :: Exp -> Type -> [(String, Type)] -> Maybe (Exp, TypeSegment, [Type])
commonHead e@(Var z) tyz cases = do
  -- (Seg st x ty1, ty2) <- headSeg t
  bodies <- mapM (return . snd) cases
  D.traceM ("commonHead.bodies = " ++ pshow bodies)
  let vars = fv bodies
  segpairs <- mapM headSeg bodies
  D.traceM ("commonHead.segpairs = " ++ pshow segpairs)
  let x' = freshvar (segName (fst $ head segpairs)) vars
  let renamedpairs = [ (seg{segName = x'}, subst (segName seg) (Var x') ty) | (seg, ty) <- segpairs]
  -- every case can be segmentized
  let segtypes = nub $ map fst renamedpairs
      segt1 = head segtypes
      (e', segt1') = case segTy segt1 of
             TSingle z' | z == z' -> (Var x', segt1 {segTy = tyz})
             _ -> (e, segt1)
  D.traceM ("commonHead.segtypes = " ++ pshow segtypes)
  if length segtypes /= 1 || z `elem` fv segt1'
    then fail ("too many segtypes/freevars: " ++ pshow (segtypes, segt1') )
    else do
    return (e', segt1', map snd renamedpairs)


