package main

import (
	"fmt"
	"log"
	"os"
	"time"
)

func main() {
	hostname, err := os.Hostname()
	if err != nil {
		log.Fatalf("Could not get hostname: %v", err)
	}

	fmt.Println("Hello from Zypgo!")
	fmt.Printf("Container ID: %s\n", hostname)
	fmt.Printf("Time: %s\n", time.Now().UTC().Format(time.RFC3339))

	for {
		fmt.Println("Go application still running...")
		time.Sleep(10 * time.Second)
	}
}

