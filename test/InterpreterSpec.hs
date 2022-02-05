{-# OPTIONS_GHC -Wall #-}
module InterpreterSpec (spec) where
import Test.Hspec
import Utils

import Kinds
import Syntax
import ProcessEnvironment
import UtilsFuncCcldlc

spec :: Spec
spec = do
  describe "LDGV interpretation of single arithmetic declarations" $ do
    it "compares integer and double value" $
      VInt 42 == VDouble 42.0 `shouldBe` False
    it "interprets 12 + 56" $
      DFun "f" [] (Math $ Add (Lit $ LNat 12) (Lit $ LNat 56)) Nothing
      `shouldInterpretTo`
      VInt 68
    it "interprets 12.34 + 56.78" $
      DFun "f" [] (Math $ Add (Lit $ LDouble 12.34) (Lit $ LDouble 56.78)) Nothing
      `shouldInterpretTo`
      VDouble 69.12
    it "interprets 2.0 * (1.0 - 3.0) / 4.0" $
      DFun "f" [] (Math $ Div (Math $ Mul (Lit $ LDouble 2.0) (Math $ Sub (Lit $ LDouble 1.0) (Lit $ LDouble 3.0))) (Lit $ LDouble 4.0)) Nothing
      `shouldInterpretTo`
      VDouble (-1.0)

  describe "LDLC function interpretation" $ do
    it "interprets application of (x='F, y='F) on section2 example function f" $
      shouldInterpretInPEnvTo [boolType, notFunc]
       (DFun "f" [] (App (App f
          (Lit (LLab "'F"))) (Lit (LLab "'F"))) Nothing)
        (VLabel "'T")

  describe "LDLC pair interpretation" $ do
    it "interprets function returning a <Bool, Int> pair: <x='T, 1>" $
      shouldInterpretInPEnvTo [boolType]
        (DFun "f" [] (Pair MMany "x" (Lit (LLab "'T")) (Lit $ LNat 1)) Nothing)
        (VPair (VLabel "'T") (VInt 1))
    it "interprets function returning a <Bool, Int> pair, where snd depends on evaluation of fst: <x='T, case x {'T: 1, 'F: 0}>" $
      shouldInterpretInPEnvTo [boolType]
        (DFun "f" [] (Pair MMany "x" (Lit $ LLab "'T") (Case (Var "x") [("'T",Lit $ LNat 1), ("'F",Lit $ LNat 0)])) Nothing)
        (VPair (VLabel "'T") (VInt 1))

  describe "CCLDLC function interpretation" $ do
    it "interprets application of x='F, y=('F: Bool => *) on section2 example function f1'" $
      shouldInterpretInPEnvTo [boolType, notFunc]
        (DFun "f1'" [] (App (App f1' (Lit $ LLab "'F")) (Cast (Lit $ LLab "'F") (TName False "Bool") TDyn)) Nothing)
        (VLabel "'T")
    it "interprets application of x=('F: Bool => *), y='F on section2 example function f2'" $
      shouldInterpretInPEnvTo [boolType, notFunc]
        (DFun "f2'" [] (App (App f2' (Cast (Lit (LLab "'F")) (TName False "Bool") TDyn)) (Lit (LLab "'F"))) Nothing)
        (VLabel "'T")
    it "interprets application of x=('T: Bool -> *), y=6 on section2 example function f2'" $
      shouldInterpretInPEnvTo [boolType, notFunc]
        (DFun "f2'" [] (App (App f2' (Cast (Lit (LLab "'T")) (TName False "Bool") TDyn)) (Lit (LNat 6))) Nothing)
        (VInt 23)
    it "interprets application of x=('F: MaybeBool => *), y='F on section2 example function f2'" $
      shouldThrowCastException [boolType, notFunc, maybeBoolType]
        (DFun "f2'" [] (App (App f2' (Cast (Lit (LLab "'F")) (TName False "MaybeBool") TDyn)) (Lit (LLab "'F"))) Nothing)
    it "interprets application of x=('F: MaybeBool => Bool), y='F on section2 example function f" $
      shouldThrowCastException [boolType, notFunc, maybeBoolType]
        (DFun "f" [] (App (App f (Cast (Lit (LLab "'F")) (TName False "MaybeBool") (TName False "Bool"))) (Lit (LLab "'F"))) Nothing)
    it "interprets application of x=('T: OnlyTrue => Bool), y='6 on section2 example function f" $
      shouldInterpretInPEnvTo [boolType, notFunc, onlyTrueType]
        (DFun "f" [] (App (App f (Cast (Lit (LLab "'T")) (TName False "OnlyTrue") (TName False "Bool"))) (Lit (LNat 6))) Nothing)
        (VInt 23)
    it "interprets application of x=('T: OnlyTrue => *), y=6 on section2 example function f2'" $
      shouldInterpretInPEnvTo [boolType, notFunc, onlyTrueType]
        (DFun "f2'" [] (App (App f2' (Cast (Lit (LLab "'T")) (TName False "OnlyTrue") TDyn)) (Lit (LNat 6))) Nothing)
        (VInt 23)
    it "interprets application of x='T, y=('L: Direction => *), z='T on example function f3" $
      shouldInterpretInPEnvTo [boolType, notFunc, directionType]
        (DFun "f3" [] (App (App (App f3 (Lit (LLab "'T"))) (Cast (Lit (LLab "'R")) (TName False "Direction") TDyn)) (Lit (LLab "'T"))) Nothing)
        (VLabel "'F")
    it "interprets application of x='F,y=(not: (b:Bool) -> Bool => *),z='T on example function f4'" $
      shouldInterpretInPEnvTo [boolType, notFunc]
        (DFun "f4'" []
          (App (App (App f4'
            (Lit (LLab "'F")))
              (Cast (Var "not") (TFun MMany "b" (TName False "Bool") (TName False "Bool")) TDyn))
                (Lit (LLab "'T")))
          Nothing)
        (VLabel "'F")
    it "interprets application of x='T,y=(and: (a:Bool) -> (b:Bool) -> Bool),z='T on example function f4'" $
      shouldInterpretInPEnvTo [boolType, andFunc]
        (DFun "f4'" []
          (App (App (App f4'
            (Lit (LLab "'T")))
              (Cast (Var "and") (TFun MMany "a" (TName False "Bool")  (TFun MMany "b" (TName False "Bool") (TName False "Bool"))) TDyn))
                (Lit (LLab "'T")))
          Nothing)
        (VLabel "'T")
    it "interprets cast of boolean pair from Bool to OnlyTrue" $
      shouldThrowCastException [boolType, onlyTrueType]
      (DFun "paircast" []
        (Cast
          (Pair MMany "x"
            (Cast (Lit (LLab "'T")) (TName False "Bool") TDyn)
            (Case (Cast (Var "x") TDyn (TName False "Bool")) [("'T",Lit (LLab "'T")),("'F",Lit (LLab "'F"))]))
          (TPair MMany "x" (TName False "Bool") (TName False "Bool"))
          (TPair MMany "x" (TName False "OnlyTrue") (TName False "OnlyTrue")))
        Nothing)
    it "interprets cast of boolean pair from Bool to MaybeBool" $
      shouldInterpretInPEnvTo [boolType, maybeBoolType]
      (DFun "paircast" []
        (Cast
          (Pair MMany "x"
            (Cast (Lit (LLab "'T")) (TName False "Bool") TDyn)
            (Case (Cast (Var "x") TDyn (TName False "Bool")) [("'T",Lit (LLab "'T")),("'F",Lit (LLab "'F"))]))
          (TPair MMany "x" (TName False "Bool") (TName False "Bool"))
          (TPair MMany "x" (TName False "MaybeBool") (TName False "MaybeBool")))
        Nothing)
      (VPair (VDynCast (VLabel "'T") (GLabel (labelsFromList ["'T", "'F"]))) (VLabel "'T"))
    it "interprets dynamic plus function with x=(5:Int->*),y=(8:Int->*)" $
      DFun "plus" [] (App (App (Lam MMany "x" TDyn (Lam MMany "y" TDyn (Math (Add (Var "x") (Var "y")))))
          (Cast (Lit $ LInt 5) TInt TDyn)) (Cast (Lit $ LInt 8) TInt TDyn))
        Nothing
      `shouldInterpretTo`
      VInt 13
