package tieba

import (
	"errors"
	"fmt"
)

type wireField struct {
	number int
	wire   int
	value  uint64
	bytes  []byte
}

func appendVarint(dst []byte, value uint64) []byte {
	for value >= 0x80 {
		dst = append(dst, byte(value)|0x80)
		value >>= 7
	}
	return append(dst, byte(value))
}

func appendTag(dst []byte, number, wire int) []byte {
	return appendVarint(dst, uint64(number<<3|wire))
}

func appendUint(dst []byte, number int, value uint64) []byte {
	if value == 0 {
		return dst
	}
	dst = appendTag(dst, number, 0)
	return appendVarint(dst, value)
}

func appendBytes(dst []byte, number int, value []byte) []byte {
	if len(value) == 0 {
		return dst
	}
	dst = appendTag(dst, number, 2)
	dst = appendVarint(dst, uint64(len(value)))
	return append(dst, value...)
}

func appendString(dst []byte, number int, value string) []byte {
	return appendBytes(dst, number, []byte(value))
}

func readVarint(data []byte, offset *int) (uint64, error) {
	var value uint64
	for shift := 0; shift < 64; shift += 7 {
		if *offset >= len(data) {
			return 0, errors.New("truncated protobuf varint")
		}
		b := data[*offset]
		*offset++
		value |= uint64(b&0x7f) << shift
		if b < 0x80 {
			return value, nil
		}
	}
	return 0, errors.New("protobuf varint overflow")
}

func parseFields(data []byte) ([]wireField, error) {
	fields := make([]wireField, 0, 8)
	for offset := 0; offset < len(data); {
		tag, err := readVarint(data, &offset)
		if err != nil {
			return nil, err
		}
		field := wireField{number: int(tag >> 3), wire: int(tag & 7)}
		if field.number == 0 {
			return nil, errors.New("invalid protobuf field number 0")
		}
		switch field.wire {
		case 0:
			field.value, err = readVarint(data, &offset)
		case 1:
			if offset+8 > len(data) {
				err = errors.New("truncated protobuf fixed64")
			} else {
				offset += 8
			}
		case 2:
			var size uint64
			size, err = readVarint(data, &offset)
			if err == nil {
				if size > uint64(len(data)-offset) {
					err = errors.New("truncated protobuf bytes")
				} else {
					field.bytes = data[offset : offset+int(size)]
					offset += int(size)
				}
			}
		case 5:
			if offset+4 > len(data) {
				err = errors.New("truncated protobuf fixed32")
			} else {
				offset += 4
			}
		default:
			err = fmt.Errorf("unsupported protobuf wire type %d", field.wire)
		}
		if err != nil {
			return nil, fmt.Errorf("field %d: %w", field.number, err)
		}
		fields = append(fields, field)
	}
	return fields, nil
}

func firstBytes(fields []wireField, number int) []byte {
	for _, field := range fields {
		if field.number == number && field.wire == 2 {
			return field.bytes
		}
	}
	return nil
}

func allBytes(fields []wireField, number int) [][]byte {
	var values [][]byte
	for _, field := range fields {
		if field.number == number && field.wire == 2 {
			values = append(values, field.bytes)
		}
	}
	return values
}

func firstUint(fields []wireField, number int) uint64 {
	for _, field := range fields {
		if field.number == number && field.wire == 0 {
			return field.value
		}
	}
	return 0
}

func firstString(fields []wireField, number int) string {
	return string(firstBytes(fields, number))
}
