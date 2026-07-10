package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Println("hello from a manually constructed OCI image")

	data, err := os.ReadFile("/etc/image-message.txt")
	if err != nil {
		panic(err)
	}

	fmt.Print(string(data))
}
