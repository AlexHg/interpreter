module Compiler.Tokenizer
  ( Tokenizer (..)
  , tokenizer
  ) where

import           Compiler.Token

-- | A tokenizer is a data structure which is incrementally fed characters and incrementally returns tokens.
data Tokenizer = TokenizerEndOfFile Position
               | TokenizerToken Position Token Tokenizer
               -- | Passed Nothing if at EOF.
               | TokenizerCharRequest (Maybe Char -> Tokenizer)
               | TokenizerError Position

-- | The char will be the next one presented to a char request. This allows for peeking at a char.
present :: Char -> Tokenizer -> Tokenizer
present c t@(TokenizerEndOfFile pos)   = t
present c   (TokenizerToken pos tok t) = TokenizerToken pos tok (present c t)
present c   (TokenizerCharRequest k)   = k (Just c)
present c t@(TokenizerError pos)       = t

tokenizer :: Tokenizer
tokenizer = unsure posStart

-- | Start of file or after two blank lines.
unsure :: Position -> Tokenizer
unsure pos = TokenizerCharRequest check
  where check Nothing = TokenizerEndOfFile pos
        check (Just c) = test c
        test ' '  = unsureSpaces (colSucc pos)
        test '\n' = unsure (lineSucc pos)
        test c    = commentBlock (colSucc pos)

unsureSpaces :: Position -> Tokenizer
unsureSpaces pos = TokenizerCharRequest check
  where check Nothing = TokenizerEndOfFile pos
        check (Just c) = test c
        test ' '  = unsureSpaces (colSucc pos)
        test '\n' = unsure (lineSucc pos)
        test c    = present c $ tok pos

commentBlock :: Position -> Tokenizer
commentBlock pos = TokenizerCharRequest check
  where check Nothing = TokenizerEndOfFile pos
        check (Just c) = test c
        test '\n' = commentBlankLine1 (lineSucc pos)
        test c    = commentBlock (colSucc pos)

commentBlankLine1 :: Position -> Tokenizer
commentBlankLine1 pos = TokenizerCharRequest check
  where check Nothing = TokenizerEndOfFile pos
        check (Just c) = test c
        test ' '  = commentBlankLine1 (colSucc pos)
        test '\n' = commentBlankLine2 (lineSucc pos)
        test c    = commentBlock (colSucc pos)

commentBlankLine2 :: Position -> Tokenizer
commentBlankLine2 pos = TokenizerCharRequest check
  where check Nothing = TokenizerEndOfFile pos
        check (Just c) = test c
        test '\n' = unsure (lineSucc pos)
        test ' '  = commentBlankLine2 (colSucc pos)
        test c    = commentBlock (colSucc pos)

codeBlankLine1 :: Position -> Tokenizer
codeBlankLine1 pos = TokenizerCharRequest check
  where check Nothing = TokenizerEndOfFile pos
        check (Just c) = test c
        test '\n' = codeBlankLine2 (lineSucc pos)
        test ' '  = codeBlankLine1 (colSucc pos)
        test c    = present c $ tok pos

codeBlankLine2 :: Position -> Tokenizer
codeBlankLine2 pos = TokenizerCharRequest check
  where check Nothing = TokenizerEndOfFile pos
        check (Just c) = test c
        test '\n' = unsure (lineSucc pos)
        test ' '  = codeBlankLine2 (colSucc pos)
        test c    = present c $ tok pos

-- The main token matcher.
tok :: Position -> Tokenizer
tok pos = TokenizerCharRequest check
  where check Nothing  = TokenizerEndOfFile pos
        check (Just c) = test c
        test '-'  = dash (colSucc pos)
        test '.'  = dot (colSucc pos)
        test ' '  = tok (colSucc pos)
        test '\n' = codeBlankLine1 (lineSucc pos)
        test '='  = TokenizerToken pos EqualsToken (tok (colSucc pos))
        test ':'  = TokenizerToken pos ColonToken (tok (colSucc pos))
        test '('  = TokenizerToken pos LeftParenToken (tok (colSucc pos))
        test ')'  = TokenizerToken pos RightParenToken (tok (colSucc pos))
        test '⟦'  = TokenizerToken pos LeftBracketToken (tok (colSucc pos))
        test '⟧'  = TokenizerToken pos RightBracketToken (tok (colSucc pos))
        test ','  = TokenizerToken pos CommaToken (tok (colSucc pos))
        test '⟶'  = TokenizerToken pos RightArrowToken (tok (colSucc pos))
        test '↦' = TokenizerToken pos RightCapArrowToken (tok (colSucc pos))
        test '_'  = TokenizerToken pos UnderbarToken (tok (colSucc pos))
        test '∘'  = TokenizerToken pos ComposeToken (tok (colSucc pos))
        test '!'  = TokenizerToken pos BangToken (tok (colSucc pos))
        test c | '0' <= c && c <= '9'
                  = digit (colSucc pos) pos [c]
        test c | 'a' <= c && c <= 'z'
                  = lower (colSucc pos) pos [c]
        test c | 'A' <= c && c <= 'Z'
                  = upper (colSucc pos) pos [c]
        test '“'  = string (colSucc pos) pos 0 []
        test _    = TokenizerError pos

dash :: Position -> Tokenizer
dash pos = TokenizerCharRequest check
  where check Nothing = TokenizerError pos
        check (Just c) = test c
        test '-' = skipLine (colSucc pos)
        test _ = TokenizerError pos

skipLine :: Position -> Tokenizer
skipLine pos = TokenizerCharRequest check
  where check Nothing = TokenizerEndOfFile pos
        check (Just c) = test c
        test '\n' = codeBlankLine1 (lineSucc pos)
        test _    = skipLine (colSucc pos)

dot :: Position -> Tokenizer
dot pos = TokenizerCharRequest check
  where check Nothing = TokenizerError pos
        check (Just c) = test c
        test c | 'a' <= c && c <= 'z' = dotLower (colSucc pos) pos [c]
        test c | 'A' <= c && c <= 'Z' = dotUpper (colSucc pos) pos [c]
        test _ = TokenizerError pos

-- | In digit, lower, and upper, we pass a reversed string of matched characters to use when matching is complete.
type Reversed a = a

digit :: Position -> Position -> Reversed String -> Tokenizer
digit pos' pos cs = TokenizerCharRequest check
  where check Nothing = TokenizerToken pos (IntToken (read $ reverse cs)) (TokenizerEndOfFile pos)
        check (Just c) = test c
        test c | '0' <= c && c <= '9'
                  = digit (colSucc pos') pos (c:cs)
        test c    = TokenizerToken pos (IntToken (read $ reverse cs)) (present c $ tok pos')

lower :: Position -> Position -> Reversed String -> Tokenizer
lower pos' pos cs = TokenizerCharRequest check
  where check Nothing = TokenizerToken pos (LowerToken (reverse cs)) (TokenizerEndOfFile pos)
        check (Just c) = test c
        test c | 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9'
                  = lower (colSucc pos') pos (c:cs)
        test c    = TokenizerToken pos (LowerToken (reverse cs)) (present c $ tok pos')

upper :: Position -> Position -> Reversed String -> Tokenizer
upper pos' pos cs = TokenizerCharRequest check
  where check Nothing = TokenizerToken pos (UpperToken (reverse cs)) (TokenizerEndOfFile pos)
        check (Just c) = test c
        test c | 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9'
                  = upper (colSucc pos') pos (c:cs)
        test c    = TokenizerToken pos (UpperToken (reverse cs)) (present c $ tok pos')

dotLower :: Position -> Position -> Reversed String -> Tokenizer
dotLower pos' pos cs = TokenizerCharRequest check
  where check Nothing = TokenizerToken pos (DotLowerToken (reverse cs)) (TokenizerEndOfFile pos)
        check (Just c) = test c
        test c | 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9'
                  = dotLower (colSucc pos') pos (c:cs)
        test c    = TokenizerToken pos (DotLowerToken (reverse cs)) (present c $ tok pos')

dotUpper :: Position -> Position -> Reversed String -> Tokenizer
dotUpper pos' pos cs = TokenizerCharRequest check
  where check Nothing = TokenizerToken pos (DotUpperToken (reverse cs)) (TokenizerEndOfFile pos)
        check (Just c) = test c
        test c | 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9'
                  = dotUpper (colSucc pos') pos (c:cs)
        test c    = TokenizerToken pos (DotUpperToken (reverse cs)) (present c $ tok pos')

-- This should test to make sure only valid characters are within a string
-- literal. It should also handle escapes correctly.

-- | The integer is the nesting level, because smart quotes allow nesting of strings.
string :: Position -> Position -> Int -> Reversed String -> Tokenizer
string pos' pos n cs = TokenizerCharRequest (check n)
  where check n Nothing = TokenizerError pos
        check n (Just c) = test n c
        test n c | c == '“' = string (colSucc pos') pos (n + 1) (c:cs)
        test 0 c | c == '”' = TokenizerToken pos (StringToken (reverse cs)) (tok (colSucc pos'))
        test n c | c == '”' = string (colSucc pos') pos (n - 1) (c:cs)
        test n c            = string (colSucc pos') pos n (c:cs)
