{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE GADTs #-}
module Llvm.Pass.Rewriter where

import Control.Monad
import Data.Maybe
import Prelude hiding (succ)

import qualified Compiler.Hoopl as H

import Llvm.VmCore.CoreIr
import Llvm.VmCore.Ir
import Llvm.VmCore.Converter (maybeM)

type MaybeChange a = a -> Maybe a


f2 :: (a -> Maybe a) -> (a, a) -> Maybe (a, a) 
f2 f (a1, a2) = case (f a1, f a2) of
                  (Nothing, Nothing) -> Nothing
                  (a1', a2') -> Just (fromMaybe a1 a1', fromMaybe a2 a2')


f3 :: (a -> Maybe a) -> (a, a, a) -> Maybe (a, a, a) 
f3 f (a1, a2, a3) = case (f a1, f a2, f a3) of
                      (Nothing, Nothing, Nothing) -> Nothing
                      (a1', a2', a3') -> Just (fromMaybe a1 a1', fromMaybe a2 a2', fromMaybe a3 a3')


fs :: Eq a => (a -> Maybe a) -> [a] -> Maybe [a]
fs f ls = let ls' = map (\x -> (fromMaybe x (f x))) ls
          in if ls == ls' then Nothing else Just ls'


rwBinExpr :: MaybeChange a -> MaybeChange (BinExpr a)
rwBinExpr f e = let (v1, v2) = operandOfBinExpr e
                    t = typeOfBinExpr e
                in do { (v1', v2') <- f2 f (v1, v2)
                      ; return $ newBinExpr t v1' v2'
                      }
                    where newBinExpr t v1 v2 = 
                           case e of 
                             Add nw _ _ _ -> Add nw t v1 v2
                             Sub nw _ _ _ -> Sub nw t v1 v2
                             Mul nw _ _ _ -> Mul nw t v1 v2
                             Udiv nw _ _ _ -> Udiv nw t v1 v2
                             Sdiv nw _ _ _ -> Sdiv nw t v1 v2
                             Urem _ _ _ -> Urem t v1 v2
                             Srem _ _ _ -> Srem t v1 v2
                             Fadd _ _ _ -> Fadd t v1 v2
                             Fsub _ _ _ -> Fsub t v1 v2
                             Fmul _ _ _ -> Fmul t v1 v2
                             Fdiv _ _ _ -> Fdiv t v1 v2
                             Frem _ _ _ -> Frem t v1 v2
                             Shl nw _ _ _ -> Shl nw t v1 v2
                             Lshr nw _ _ _ -> Lshr nw t v1 v2
                             Ashr nw _ _ _ -> Ashr nw t v1 v2
                             And _ _ _ -> And t v1 v2
                             Or _ _ _ -> Or t v1 v2
                             Xor _ _ _ -> Xor t v1 v2
                           


rwConversion :: MaybeChange a -> MaybeChange (Conversion a)
rwConversion f (Conversion co tv1 t) = do { tv1' <- f tv1
                                          ; return $ Conversion co tv1' t
                                          }

rwGetElemPtr :: Eq a => MaybeChange a -> MaybeChange (GetElemPtr a)
rwGetElemPtr f (GetElemPtr b tv1 indices) = do { tv1' <- f tv1
                                               ; indices' <- fs f indices
                                               ; return $ GetElemPtr b tv1' indices'
                                               }

rwSelect :: MaybeChange a -> MaybeChange (Select a)
rwSelect f (Select tv1 tv2 tv3) = do { (tv1', tv2', tv3') <- f3 f (tv1, tv2, tv3)
                                     ; return $ Select tv1' tv2' tv3'
                                     }

rwIcmp :: MaybeChange a -> MaybeChange (Icmp a)
rwIcmp f (Icmp op t v1 v2) = do { (v1', v2') <- f2 f (v1, v2)
                                ; return $ Icmp op t v1' v2'
                                }
rwFcmp :: MaybeChange a -> MaybeChange (Fcmp a)
rwFcmp f (Fcmp op t v1 v2) = do { (v1', v2') <- f2 f (v1, v2)
                                ; return $ Fcmp op t v1' v2'
                                }


tv2v :: MaybeChange Value -> MaybeChange TypedValue
tv2v f (TypedValue t x) = liftM (TypedValue t) (f x)

rwExpr :: MaybeChange Value -> MaybeChange Expr
rwExpr f (EgEp gep) = rwGetElemPtr (tv2v f) gep >>= return . EgEp
rwExpr f (EiC a) = rwIcmp f a >>= return . EiC
rwExpr f (EfC a) = rwFcmp f a >>= return . EfC
rwExpr f (Eb a) = rwBinExpr f a >>= return . Eb
rwExpr f (Ec a) = rwConversion (tv2v f) a >>= return . Ec
rwExpr f (Es a) = rwSelect (tv2v f) a >>= return . Es
rwExpr _ (Ev _) = error "unexpected case"
                  

rwMemOp :: MaybeChange Value -> MaybeChange Rhs 
rwMemOp f (RmO (Allocate m t ms ma)) = do { ms' <- maybeM (tv2v f) ms
                                          ; return $ RmO $ Allocate m t ms' ma
                                          }
rwMemOp f (RmO (Load _ (TypedPointer (Tpointer t _) ptr) _)) = do { tv <- (tv2v f) (TypedValue t (Deref ptr))
                                                                  ; return $ Re $ Ev tv
                                                                  }
rwMemOp f (RmO (Free tv)) = (tv2v f) tv >>= return . RmO . Free 
rwMemOp f (RmO (Store a tv1 tv2 ma)) = do { tv1' <- (tv2v f) tv1
                                          ; return $ RmO $ Store a tv1' tv2 ma
                                          }
rwMemOp f (RmO (CmpXchg b ptr v1 v2 b2 fe)) = do { (v1', v2') <- f2 (tv2v f) (v1, v2)
                                                 ; return $ RmO $ CmpXchg b ptr v1' v2' b2 fe
                                                 }
rwMemOp f (RmO (AtomicRmw b ao ptr v1 b2 fe)) = do { v1' <- (tv2v f) v1
                                                   ; return $ RmO $ AtomicRmw b ao ptr v1' b2 fe
                                                   }
rwMemOp _ _ = error "impossible case"                                                

rwShuffleVector :: MaybeChange a -> MaybeChange (ShuffleVector a)
rwShuffleVector f (ShuffleVector tv1 tv2 tv3) = do { (tv1', tv2', tv3') <- f3 f (tv1, tv2, tv3)
                                                   ; return $ ShuffleVector tv1' tv2' tv3'
                                                   }
rwExtractValue :: MaybeChange a -> MaybeChange (ExtractValue a)
rwExtractValue f (ExtractValue tv1 s) = f tv1 >>= \tv1' -> return $ ExtractValue tv1' s

rwInsertValue :: MaybeChange a -> MaybeChange (InsertValue a)
rwInsertValue f (InsertValue tv1 tv2 s) = do { (tv1', tv2') <- f2 f (tv1, tv2)
                                              ; return $ InsertValue tv1' tv2' s
                                              }

rwExtractElem :: MaybeChange a -> MaybeChange (ExtractElem a)
rwExtractElem f (ExtractElem tv1 tv2) = do { (tv1', tv2') <- f2 f (tv1, tv2)
                                            ; return $ ExtractElem tv1' tv2'
                                            }

rwInsertElem :: MaybeChange a -> MaybeChange (InsertElem a)
rwInsertElem f (InsertElem tv1 tv2 tv3) = do { (tv1', tv2', tv3') <- f3 f (tv1, tv2, tv3)
                                              ; return $ InsertElem tv1' tv2' tv3'
                                              }
rwRhs :: MaybeChange Value -> MaybeChange Rhs
rwRhs f (RmO a) = rwMemOp f (RmO a) 
rwRhs _ (Call _ _) = Nothing
rwRhs f (Re a) = rwExpr f a >>= return . Re
rwRhs f (ReE a) = rwExtractElem (tv2v f) a >>= return . ReE
rwRhs f (RiE a) = rwInsertElem (tv2v f) a >>= return . RiE
rwRhs f (RsV a) = rwShuffleVector (tv2v f) a >>= return . RsV
rwRhs f (ReV a) = rwExtractValue (tv2v f) a >>= return . ReV
rwRhs f (RiV a) = rwInsertValue (tv2v f) a >>= return . RiV
rwRhs f (VaArg tv t) = (tv2v f) tv >>= \tv' -> return $ VaArg tv' t
rwRhs _ (LandingPad _ _ _ _ _) = Nothing


rwComputingInst :: MaybeChange Value -> MaybeChange ComputingInst
rwComputingInst f (ComputingInst lhs rhs) = rwRhs f rhs >>= return . (ComputingInst lhs)

rwComputingInstWithDbg :: MaybeChange Value -> MaybeChange ComputingInstWithDbg
rwComputingInstWithDbg f (ComputingInstWithDbg cinst dbgs) = rwComputingInst f cinst >>= 
                                                              \cinst' -> return $ ComputingInstWithDbg cinst' dbgs
                                                                        
rwCinst :: MaybeChange Value -> MaybeChange (Node e x)
rwCinst f (Cinst c) = rwComputingInstWithDbg f c >>= return . Cinst
rwCinst _ _ = Nothing


rwTerminatorInst :: MaybeChange Value -> MaybeChange TerminatorInst
rwTerminatorInst f (Return ls) = do { ls' <- fs (tv2v f) ls
                                    ; return $ Return ls'
                                    }
rwTerminatorInst f (Cbr v tl fl) = do { v' <- f v
                                      ; return $ Cbr v' tl fl
                                      }
rwTerminatorInst _ _  = Nothing                           
-- rwTerminatorInst f e = error ("unhandled case " ++ (show e))
                       

rwTerminatorInstWithDbg :: MaybeChange Value -> MaybeChange TerminatorInstWithDbg
rwTerminatorInstWithDbg f (TerminatorInstWithDbg cinst dbgs) = rwTerminatorInst f cinst >>= 
                                                               \cinst' -> return $ TerminatorInstWithDbg cinst' dbgs
                                                                        
rwTinst :: MaybeChange Value -> MaybeChange (Node e x)
rwTinst f (Tinst c) = rwTerminatorInstWithDbg f c >>= return . Tinst
rwTinst _ _ = Nothing


rwNode :: MaybeChange Value -> MaybeChange (Node e x)
rwNode f n@(Cinst _) = rwCinst f n
rwNode f n@(Tinst _) = rwTinst f n
rwNode _ _  = Nothing

nodeToG :: Node e x -> H.Graph Node e x
nodeToG n@(Nlabel _) = H.mkFirst n
nodeToG n@(Pinst _) = H.mkMiddle n
nodeToG n@(Cinst _) = H.mkMiddle n
nodeToG n@(Tinst _) = H.mkLast n


