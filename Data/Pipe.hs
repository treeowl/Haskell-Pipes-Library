{-
    Copyright 2012 Gabriel Gonzalez

    This file is part of the Haskell Pipes Library.

    The is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    hPDB is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with the Haskell Pipes Library.  If not, see
    <http://www.gnu.org/licenses/>.
-}

{-|
    'Pipe' is a monad transformer that extends the base monad with the ability
    to demand input from upstream 'Pipe's and provide output to downstream
    'Pipe's.  'Pipe's resemble enumeratees in other libraries.  To demonstrate,
    let's create a verbose 'Pipe' that resembles the Prelude's 'take' function:

> take' :: Int -> Pipe a a IO ()
> take' n = do
>     replicateM_ n $ do
>         x <- await -- request input from the upstream pipe and bind it to x
>         yield x    -- deliver x as output to the next downstream pipe
>     lift $ putStrLn "You shall not pass!"

    @take'@ uses 'IO' as its base monad because it invokes the 'putStrLn'
    function.  If it had not used any functions from the base monad, its type
    signature would have been:

> take' :: (Monad m) => Int -> Pipe a a m ()

    Like all monad transformers, 'Pipe' indicates the base monad using the
    second-to-last variable: @m@.  The two variables preceding the @m@
    correspond to the types of the pipe's input and output, in that order.
    Our @take'@ 'Pipe' requests input values of type @a@ and outputs values
    of the same type.

    Let's create a function that converts a list into a 'Pipe' that yields each
    element of the list successively:

> fromList :: (Monad m) => [a] -> Pipe Zero a m ()
> fromList = mapM_ yield

    The 'Zero' in the type signature indicates that this 'Pipe' won't request
    any input from an upstream 'Pipe' (since it uses the list as its input), so
    you can use @fromList@ as the first stage in a 'Pipeline'.  You can think of
    @fromList@ as a one way 'Pipe' that can only deliver output.  I provide
    a type synonym for this common case:

> type Producer b m r = Pipe Zero b m r

    It's not much shorter, but perhaps its easier on your eyes.  You can then
    rewrite the type signature for @fromList@ as:

> fromList :: (Monad m) => [a] -> Producer a m ()

    'Producer's resemble enumerators in other libraries.

    Now let's create a 'Pipe' that prints every value delivered to it and never
    terminates:

> printer :: (Show a) => Pipe a Zero IO ()
> printer = forever $ do
>     x <- await
>     lift $ print x

    The 'Zero' in @printer@'s type signature indicates that it never delivers
    output downstream, so it represents the final stage in a 'Pipeline'.  Again,
    I provide a type synonym for this common case:

> type Consumer a m r = Pipe a Zero m r

    So we can write @printer@'s type as:

> printer :: (Show a) => Consumer a IO ()

    'Consumer's resemble iteratees in other libraries.

    'Pipe's can be composed (literally) into 'Pipeline's because 'Pipe' has two
    newtypes with separate 'Category' implementations:

> newtype Lazy   m r a b = Lazy   { unLazy   :: Pipe a b m r }
> newtype Strict m r a b = Strict { unStrict :: Pipe a b m r }
> instance Category (Lazy   m r) where ...
> instance Category (Strict m r) where ...

    The first newtype composes pipes with 'Lazy' semantics and the second one
    with 'Strict' semantics.  For more details, see below, but you probably want
    the 'Lazy' semantics.

    For example, you can compose the above 'Pipe's with:

> pipeline1 :: Pipe Zero Zero IO ()
> pipeline1 :: unLazy $ Lazy printer . Lazy (take 3) . Lazy (fromList [1..])

    The above 'Pipe' doesn't 'await' any input and it 'yield's no output,
    therefore it forms a self-contained 'Pipeline'.  I provide a type synonym
    for this common case:

> type Pipeline m r = Pipe Zero Zero m r

    Also, I provide convenience operators for composing 'Pipe's without the
    burden of wrapping and unwrapping newtypes.  For example, to compose 'Pipe's
    lazily, just use the '<+<' operator:

> p1 <+< p2 = unLazy $ Lazy p1 <<< Lazy p2 -- (<<<) is the same as (.)

    So you can rewrite @pipeline1@ as:

> pipeline1 :: Pipeline IO ()
> pipeline1 = printer <+< take 3 <+< fromList [1..]

    Like many other monad transformers, you convert the 'Pipe' monad back to the
    base monad using the 'runPipe' function:

>>> runPipe pipeline1 :: IO ()
1
2
3
You shall not pass!

    'runPipe' only works on self-contained 'Pipeline's.  If a 'Pipe' is not
    self-contained, then it is not ready to be converted back to the base monad.
    'runPipe''s type signature says it all:

> runPipe :: (Monad m) => Pipeline m r -> m r

    You can easily "vertically" concatenate 'Pipe's, 'Producer's, and
    'Consumer's, using monad sequencing.  Here's an example of
    concatenating 'Producer's:

>>> runPipe $ printer <+< (fromList [1..3] >> fromList [10..12])
1
2
3
9
10
11

    Here's an example of concatenating 'Consumer's:

>>> let print3 = printer <+< take' 3 :: (Show a) => Consumer a IO ()
>>> runPipe $ (print3 >> print3) <+< fromList [1..]
1
2
3
You shall not pass!
4
5
6
You shall not pass!

   ... but the above example is gratuitous because we could have just
   concatenated the intermediate @take'@ 'Pipe':

>>> runPipe $ printer <+< (take' 3 >> take' 3) <+< fromList [1..]
1
2
3
You shall not pass!
4
5
6
You shall not pass!

    'Pipe's promote loose coupling, allowing you to mix and match them
    transparently using composition.  For example, we can define a new
    'Producer' pipe that indefinitely prompts the user for integers:

> prompt :: Producer Int IO ()
> prompt = forever $ do
>     lift $ putStrLn "Enter a number: "
>     n <- read <$> lift getLine
>     yield n

    Now we can compose it with any compatible 'Pipe':

>>> runPipe $ printer <+< take' 3 <+< prompt
Enter a number:
1<Enter>
1
Enter a number:
2<Enter>
2
Enter a number:
3<Enter>
3
You shall not pass!

    Note that both @printer@ and @prompt@ are non-terminating pipes, yet our
    entire pipeline magically terminates gracefully after @take' 3@ stops.
    Under 'Lazy' composition, if a 'Pipe' 'await's a value from a terminated
    'Pipe', instead of blocking it will terminate itself and every pipe upstream
    of it.  Downstream 'Pipe's will continue to function until they try to
    'await' output from it.

    So @printer@ terminated and shut down the entire 'Pipeline' because it
    requested a value from the terminated @take' 3@ 'Pipe'.

    Under 'Strict' composition, if a 'Pipe' 'yield's a value to a terminated
    'Pipe', instead of blocking it will terminate itself and every 'Pipe'
    downstream of it.  'Pipe's upstream of it will continue to function until
    they try to 'yield' it any input to handle.  Let's repeat the above example
    with 'Strict' composition:

>>> runPipe $ printer <-< take' 3 <-< prompt
Enter a number:
1<Enter>
Enter a number:
2<Enter>
Enter a number:
3<Enter>
1
Enter a number:
4<Enter>
2
You shall not pass!

    Wow!  Big difference!  The 'Strict' 'Pipeline' didn't even bother to print
    the first value until after the user had already entered several.  This
    marks another difference between 'Strict' and 'Lazy' 'Pipeline's.  'Lazy'
    'Pipeline's prioritize downstream 'Pipe's over upstream 'Pipe's, trying to
    generate as much output as possible before being forced to draw more input.
    'Strict' 'Pipeline's prioritize upstream 'Pipe's, drawing as much input as
    possible before being forced to generate output.  In the above example, the
    only reason it even printed values at all is because the downstream 'Pipe's
    had to process some values in order to make room for new values from
    @prompt@.  This is why I recommend using 'Lazy' composition unless your goal
    is to draw as much input as possible.

    Both types of composition work seamlessly with non-terminating 'Pipe's,
    allowing you to transparently compose infinite 'Pipe's with finite ones.

    So far I haven't discussed the 'Pipe' monad's return type and all the above
    examples use a '()' return type so I dodged the issue.  The truth is that
    there is nothing to dodge: the return type works just fine.   It's just
    poorly suited for communicating with other pipes.  I'll just list several
    disadvantages of using 'return' to communicate with other 'Pipe's:

    * 'return' forces tight coupling between 'Pipe's whereas 'yield' promotes
      loose coupling

    * 'return' can't communicate anything until the 'Pipe' terminates, whereas
      'yield' will deliver output immediately.  'return' won't even work for
      non-terminating 'Pipe's.

    * A 'Pipe''s return value can only be bound within a 'Pipe' of the same
      type, leading to very brittle and non-compositional code.

    Return values do serve a useful purpose, though, which is that when you run
    a 'Pipe', it will return a value in the base monad.  For 'Lazy' semantics
    this will correspond to the return value of the most downstream 'Pipe' that
    terminated.  For 'Strict' semantics, it will correspond to the return value
    of the most upstream 'Pipe' that terminated.  So while return values are
    useless for communicating values between 'Pipe's they are indispensable for
    communicating results back to the base monad upon running the 'Pipe'.

    There is one last issue of polymorphism in 'Pipe' type signatures.  A
    function that 'await's values of type 'Int' but never 'yield's anything will
    actually have a fully-polymorphic type signature of @Pipe Int b m r@, since
    the compiler can't deduce the type of the output.  Similarly, a function
    that only 'yield's 'Int's but never 'await's anything would have a
    fully-polymorphic type of @Pipe a Int m r@.  The 'Consumer', 'Producer', and
    'Pipeline' type synonyms actually restrict the type of the 'Pipe'.

    If we composed our two polymorphic pipes, we'd get a final type of
    @Pipe a b m r@ which is polymorphic on both the input and output.  This
    tells us that this composite 'Pipe' neither demands input nor delivers
    output.  This composite 'Pipe' is completely compatible with the 'runPipe'
    function since 'runPipe' will just assume that @a@ and @b@ are @Zero@.

    So when you define 'Consumer', 'Producer', and 'Pipeline' 'Pipe's, you can
    opt to give them the fully-polymorphic type signature instead of using the
    'Zero' type to cover up unused ends.  Their fully-polymorphic versions will
    allow you to compose any pipe at the unused end as long as you understand
    that it will block if it tries to communicate with the unused end.  I
    personally prefer to use the 'Zero' type to cover up unused 'Pipe' ends so
    that the type system will prevent you from unintentionally trying to use
    them.

    I would like to acknowledge Mario Blazevic, whose excellent concurrency
    article in Issue 19 of The Monad Reader was the inspiration for this
    library.
-}
module Data.Pipe (module Data.Pipe.Common) where

import Data.Pipe.Common
