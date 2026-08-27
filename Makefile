.PHONY: build test vet check install mobile-aar mobile-analyze mobile-test mobile-check

build:
	go build -buildvcs=false -o mixsocial ./cmd/mixsocial

test:
	go test ./...

vet:
	go vet -buildvcs=false ./...

check: test vet build

install:
	./install.sh

mobile-aar:
	./mobile/scripts/build_go_core.sh

mobile-analyze:
	cd mobile && flutter analyze

mobile-test:
	cd mobile && flutter test

mobile-check: mobile-analyze mobile-test
