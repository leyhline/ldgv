{-# LANGUAGE LambdaCase #-}

module ProcessEnvironment where
import Syntax as S
import Control.Concurrent.Chan as C
import Control.Monad.Reader as T
import Data.Set (Set)
import qualified Data.Set as Set

-- | the interpretation monad
type InterpretM a = T.ReaderT PEnv IO a

extendEnv :: String -> Value -> PEnv -> PEnv
extendEnv = curry (:)

-- | a Process Envronment maps identifiers to Values of expressions and stores
type PEnv = [PEnvEntry]
type PEnvEntry = (String, Value)

type Label = String
type LabelType = Set Label

labelsFromList :: [Label] -> LabelType
labelsFromList = Set.fromList

data FuncType = FuncType PEnv String S.Type S.Type
  deriving Eq

instance Show FuncType where
  show (FuncType _ s t1 t2) = "FuncType " ++ show s ++ " " ++ show t1 ++ " " ++ show t2

-- | (Unit, Label, Int, Values of self-declared Data Types), Channels
data Value
  = VUnit
  | VLabel String
  | VInt Int
  | VDouble Double
  | VString String
  -- we have two channels, one for reading and one for writing to the other
  -- end, so we do not read our own written values
  | VChan (C.Chan Value) (C.Chan Value)
  | VSend Value
  | VPair Value Value -- pair of ids that map to two values
  | VType S.Type
  | VFunc PEnv String Exp
  | VDynCast Value GType -- (Value : G => *)
  | VFuncCast Value FuncType FuncType -- (Value : (ρ,α,Π(x:A)A') => (ρ,α,Π(x:B)B'))
  | VRec PEnv String String Exp Exp
  | VNewNatRec PEnv String String String Type Exp String Exp
  deriving Eq

instance Show Value where
  show = \case
    VUnit -> "VUnit"
    VLabel s -> "VLabel " ++ s
    VInt i -> "VInt " ++ show i
    VDouble d -> "VDouble " ++ show d
    VString s -> "VString \"" ++ show s ++ "\""
    VChan _ _ -> "VChan"
    VSend v -> "VSend (" ++ show v ++ ")"
    VPair a b -> "VPair <" ++ show a ++ ", " ++ show b ++ ">"
    VType t -> "VType " ++ show t
    VFunc _ s exp -> "VFunc " ++ show s ++ " " ++ show exp
    VDynCast v t -> "VDynCast (" ++ show v ++ ") (" ++ show t ++ ")"
    VFuncCast v ft1 ft2 -> "VFuncCast (" ++ show v ++ ") (" ++ show ft1 ++ ") (" ++ show ft2 ++ ")"
    VRec env f x e1 e0 -> "VRec " ++ " " ++ f ++ " " ++ x ++ " " ++ show e1 ++ " " ++ show e0
    VNewNatRec env f n tid ty ez x es -> "VNewNatRec " ++ f ++ n ++ tid ++ show ty ++ show ez ++ x ++ show es

class Subtypeable t where
  isSubtypeOf :: t -> t -> Bool

-- Types in Head Normal Form
data NFType
  = NFBot
  | NFDyn
  | NFFunc FuncType  -- (ρ, α, Π(x: A) B)
  | NFPair FuncType  -- (ρ, α, Σ(x: A) B)
  | NFGType GType -- every ground type is also a type in normal form
  deriving (Show, Eq)

instance Subtypeable NFType where
  -- NFFunc and NFPair default to false, which is not really correct.
  -- Implementation would be quite complicated and its not necessary,
  -- i.e. not used anywhere.
  isSubtypeOf NFBot _ = True
  isSubtypeOf NFDyn NFDyn = True
  isSubtypeOf (NFGType gt1) (NFGType gt2) = gt1 `isSubtypeOf` gt2
  isSubtypeOf _ _ = False

data GType
  = GUnit
  | GLabel LabelType
  | GFunc String -- Π(x: *) *
  | GPair String -- Σ(x: *) *
  | GNat
  | GNatLeq Integer
  | GInt
  | GDouble
  | GString
  deriving (Show, Eq)

instance Subtypeable GType where
  isSubtypeOf GUnit GUnit = True
  isSubtypeOf (GLabel ls1) (GLabel ls2) = ls1 `Set.isSubsetOf` ls2
  isSubtypeOf (GFunc _) (GFunc _) = True
  isSubtypeOf (GPair _) (GPair _) = True
  isSubtypeOf GNat GNat = True
  isSubtypeOf (GNatLeq _) GNat = True
  isSubtypeOf (GNatLeq n1) (GNatLeq n2) = n1 <= n2
  isSubtypeOf GInt GInt = True
  isSubtypeOf GDouble GDouble = True
  isSubtypeOf GString GString = True
  isSubtypeOf _ _ = False
