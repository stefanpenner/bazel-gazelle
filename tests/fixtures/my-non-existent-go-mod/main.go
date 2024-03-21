package main

import "fmt"
import "rsc.io/quote"

func main() {
  fmt.Println(Ping())
}

func Ping() string {
  return "Pong" + quote.Hello()
}

