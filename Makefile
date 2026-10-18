# Build and run the app (app/run.sh does the work).
#
#   make device         on the paired iPhone (it must be unlocked)
#   make iphone-sim     in an iPhone simulator (IPHONE="iPhone 17" picks one)
#   make ipad-sim       in an iPad simulator (IPAD="iPad Air 13-inch (M4)" picks one)
#   make selftest       the end-to-end checks in the iPhone simulator
#   make archive        the App Store archive and .ipa in app/build (app/scripts/archive.sh)
#   make upload         the same, uploaded to App Store Connect (TestFlight)
#
# ARGS are passed on to run.sh, e.g. make iphone-sim ARGS=--reset.

IPHONE ?=
IPAD ?=
ARGS ?=

.PHONY: device iphone-sim ipad-sim selftest archive upload

device:
	cd app && ./run.sh --device $(ARGS)

iphone-sim:
	cd app && SIM="$$(./scripts/simulator.sh iphone "$(IPHONE)")" ./run.sh $(ARGS)

ipad-sim:
	cd app && SIM="$$(./scripts/simulator.sh ipad "$(IPAD)")" ./run.sh $(ARGS)

selftest:
	cd app && SIM="$$(./scripts/simulator.sh iphone "$(IPHONE)")" ./run.sh --selftest $(ARGS)

archive:
	cd app && ./scripts/archive.sh

upload:
	cd app && ./scripts/archive.sh --upload
