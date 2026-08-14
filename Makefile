.PHONY: build test vet check install

build:
	go build -buildvcs=false -o mixsocial ./cmd/mixsocial

test:
	go test ./...

vet:
	go vet -buildvcs=false ./...

check: test vet build

install:
	./install.sh
