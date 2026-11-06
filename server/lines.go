package main

import (
	"bufio"
	"errors"
	"io"
	"log"
)

// forEachLine calls fn for every line up to maxBytes long. Longer lines are logged and
// skipped, so one damaged or oversize line can never stop a whole log from loading.
func forEachLine(r io.Reader, maxBytes int, fn func([]byte)) error {
	reader := bufio.NewReaderSize(r, maxBytes)
	skipping := false
	for {
		data, err := reader.ReadSlice('\n')
		switch {
		case errors.Is(err, bufio.ErrBufferFull):
			if !skipping {
				log.Printf("log: skipping a line over %d bytes", maxBytes)
			}
			skipping = true
			continue
		case err != nil && !errors.Is(err, io.EOF):
			return err
		}
		if skipping {
			skipping = false
		} else if len(data) > 0 {
			fn(trimNewline(data))
		}
		if err != nil {
			return nil
		}
	}
}

func trimNewline(data []byte) []byte {
	if n := len(data); n > 0 && data[n-1] == '\n' {
		data = data[:n-1]
	}
	return data
}
