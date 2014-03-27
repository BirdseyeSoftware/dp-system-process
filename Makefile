.repos:
	[[ -d vendor ]] || mkdir vendor

	[[ -d vendor/distributed-process ]] || \
	{ cd vendor; git clone -b be https://github.com/BirdseyeSoftware/distributed-process; }

	[[ -d vendor/distributed-process-platform ]] || \
	{ cd vendor; git clone -b be https://github.com/BirdseyeSoftware/distributed-process-platform; }

	[[ -d vendor/network-transport ]] || \
	{ cd vendor; git clone -b development https://github.com/haskell-distributed/network-transport; }

	[[ -d vendor/network-transport-inmemory ]] || \
	{ cd vendor; git clone -b development https://github.com/haskell-distributed/network-transport-inmemory; }
	touch .repos

.setup: .repos
	cabal sandbox init
	cabal sandbox add-source vendor/distributed-process
	cabal sandbox add-source vendor/distributed-process-platform
	cabal sandbox add-source vendor/network-transport
	cabal sandbox add-source vendor/network-transport-inmemory
	touch .setup

.installed: .setup dp-system-process.cabal
	cabal install --enable-tests --only-dependencies
	touch .installed

.PHONY: setup
setup: .installed

.PHONY: unsetup
unsetup:
	cabal sandbox delete
	rm .setup

.PHONY: test
test: setup
	cabal test --show-details=always
