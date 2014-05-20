-- The driver is a monad which manages state which is passed between compiler stages.

module Compiler.Driver where

import           Control.Monad
import           System.Exit                 (exitFailure)
import           System.IO

import qualified Compiler.C.Converter        as C.Converter
import qualified Compiler.CPS                as CPS
import qualified Compiler.CPS.Check          as CPS.Check
import qualified Compiler.CPS.FromLinear        as CPS.FromLinear
import qualified Compiler.CPS.Interpreter    as Interpreter
import qualified Compiler.Direct             as Direct
import qualified Compiler.Direct.Check       as Direct.Check
import qualified Compiler.Direct.Converter   as Direct.Converter
import qualified Compiler.Direct.Interpreter as Direct.Interpreter
import qualified Compiler.Elaborator         as Elaborator
import qualified Compiler.Linear             as Linear
import qualified Compiler.Linear.Converter   as Linear.Converter
import qualified Compiler.Meta               as Meta
import           Compiler.Parser
import qualified Compiler.Simple             as Simple
import qualified Compiler.Simple.Check       as Simple.Check
import qualified Compiler.Simple.Interpreter as Simple.Interpreter
import qualified Compiler.Syntax             as Syntax
import qualified Compiler.SyntaxChecker      as SyntaxChecker
import           Compiler.Token
import           Compiler.Tokenizer
import qualified Compiler.TypeChecker        as TypeChecker

data Driver a = DriverReturn a
              | DriverPerformIO (IO (Driver a))
              | DriverError String

instance Monad Driver where
  return = DriverReturn
  DriverReturn x     >>= f = f x
  DriverPerformIO io >>= f = DriverPerformIO $ liftM (f =<<) io
  DriverError msg    >>= f = DriverError msg

drive :: Driver a -> IO a
drive (DriverReturn a)     = return a
drive (DriverPerformIO io) = io >>= drive
drive (DriverError msg)    = hPutStrLn stderr msg >> exitFailure

liftIO :: IO a -> Driver a
liftIO io = DriverPerformIO (liftM return io)

-- | Takes a filename and interprets the file.
interpreter :: String -> Driver ()
interpreter = parse         >=> strict
          >=> syntaxCheck   >=> strict
          >=> typeCheck     >=> strict
          >=> elaborate     >=> strict >=> simpleCheck
          >=> linearConvert >=> strict
          >=> cpsConvert    >=> strict >=> cpsCheck >=> return (error "done")
          {-
          >=> directConvert >=> strict >=> directCheck
          >=> directInterpret
          -}

{-
-- | Takes a filename and outputs C code to file stdout.
compiler :: String -> Driver ()
compiler = parse
       >=> syntaxCheck   >=> strict
       >=> typeCheck     >=> strict
       >=> elaborate     >=> strict >=> simpleCheck
       >=> cpsConvert    >=> strict >=> cpsCheck
       >=> directConvert >=> strict >=> directCheck
       >=> cConvert
-}

-- | Writes the value to stdout to make sure it is fully evaluated at this point.
strict :: Show a => a -> Driver a
strict x = liftIO (writeFile "/dev/null" (show x)) >> return x

-- | Used for testing purposes only.
tokenize :: String -> Driver [(Position, Token)]
tokenize filename = do
  handle <- liftIO $ openFile filename ReadMode
  x <- hTokenize filename handle
  liftIO $ hClose handle
  return x

hTokenize :: String -> Handle -> Driver [(Position, Token)]
hTokenize filename handle = tokenize tokenizer
  where tokenize :: Tokenizer -> Driver [(Position, Token)]
        tokenize (TokenizerEndOfFile pos)     = return []
        tokenize (TokenizerToken pos tok t)   = liftM ((pos, tok) :) (tokenize t)
        tokenize (TokenizerCharRequest k)     = liftIO (maybeHGetChar handle) >>= (tokenize . k)
        tokenize (TokenizerError (line, col)) = DriverError $ filename ++ ":" ++ show line ++ ":" ++ show col ++ ": Tokenizer error."

parse :: String -> Driver Syntax.Program
parse filename = do
  handle <- liftIO $ openFile filename ReadMode
  x <- hParse filename handle
  liftIO $ hClose handle
  return x

hParse :: String -> Handle -> Driver Syntax.Program
hParse filename handle = parse (parser filename)
  where parse :: Parser -> Driver Syntax.Program
        parse (ParserFinished prog)              = return prog
        parse (ParserCharRequest k)              = liftIO (maybeHGetChar handle) >>= (parse . k)
        parse (ParserError (line, col) "")       = DriverError $ filename ++ ":" ++ show line ++ ":" ++ show col ++ ": Parser error."
        parse (ParserError (line, col) msg)      = DriverError $ filename ++ ":" ++ show line ++ ":" ++ show col ++ ": Parser error. " ++ msg
        parse (ParserTokenizerError (line, col)) = DriverError $ filename ++ ":" ++ show line ++ ":" ++ show col ++ ": Tokenizer error."

maybeHGetChar :: Handle -> IO (Maybe Char)
maybeHGetChar handle = check =<< hIsEOF handle
  where check True  = return Nothing
        check False = liftM Just $ hGetChar handle

syntaxCheck :: Syntax.Program -> Driver Syntax.Program
syntaxCheck x = check $ SyntaxChecker.syntaxCheckProgram x
  where check Nothing    = return x
        check (Just msg) = DriverError msg

typeCheck :: Syntax.Program -> Driver Syntax.Program
typeCheck x = check $ TypeChecker.inferProgram (Meta.addMetavariables x)
  where check (Left msg) = DriverError msg
        check (Right x') = return x'

elaborate :: Syntax.Program -> Driver Simple.Program
elaborate x = return $ Elaborator.elaborate x

simpleCheck :: Simple.Program -> Driver Simple.Program
simpleCheck x = check $ Simple.Check.check x
  where check Nothing  = return x
        check (Just s) = DriverError $ "simple check failed: " ++ s

simpleInterpret :: Simple.Program -> Driver ()
simpleInterpret p = check $ Simple.Interpreter.interpret p
  where check Simple.Interpreter.ExitStatus         = return ()
        check (Simple.Interpreter.EscapeStatus _ _) = DriverError "interpreter resulted in an uncaught throw"
        check Simple.Interpreter.UndefinedStatus    = DriverError "interpreter resulted in unreachable"
        check (Simple.Interpreter.WriteStatus s x)  = liftIO (putStrLn s) >> check x

linearConvert :: Simple.Program -> Driver Linear.Program
linearConvert x = return $ Linear.Converter.convert x

cpsConvert :: Linear.Program -> Driver CPS.Program
cpsConvert x = return $ CPS.FromLinear.convert x

cpsCheck :: CPS.Program -> Driver CPS.Program
cpsCheck x = check $ CPS.Check.check x
  where check Nothing  = return x
        check (Just s) = DriverError $ "cps check failed: " ++ s

cpsInterpret :: CPS.Program -> Driver ()
cpsInterpret p = check $ Interpreter.interpret p
  where check Interpreter.ExitStatus         = return ()
        check (Interpreter.EscapeStatus _ _) = DriverError "interpreter resulted in an uncaught throw"
        check Interpreter.UndefinedStatus    = DriverError "interpreter resulted in unreachable"
        check (Interpreter.WriteStatus s x)  = liftIO (putStrLn s) >> check x

directConvert :: CPS.Program -> Driver Direct.Program
directConvert x = return $ Direct.Converter.convert x

directCheck :: Direct.Program -> Driver Direct.Program
directCheck x = check $ Direct.Check.check x
  where check Nothing  = return x
        check (Just s) = DriverError $ "direct check failed: " ++ s

directInterpret :: Direct.Program -> Driver ()
directInterpret p = check $ Direct.Interpreter.interpret p
  where check Direct.Interpreter.ExitStatus         = return ()
        check (Direct.Interpreter.EscapeStatus _ _) = DriverError "interpreter resulted in an uncaught throw"
        check Direct.Interpreter.UndefinedStatus    = DriverError "interpreter resulted in unreachable"
        check (Direct.Interpreter.WriteStatus s x)  = liftIO (putStrLn s) >> check x

cConvert :: Direct.Program -> Driver ()
cConvert x = liftIO $ C.Converter.convert stdout x
