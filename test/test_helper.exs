{_, 0} = System.cmd("epmd", ["-daemon"])
# credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
node = :"snex_test-#{System.pid()}@127.0.0.1"
Node.start(node, :longnames)
ExUnit.start()
