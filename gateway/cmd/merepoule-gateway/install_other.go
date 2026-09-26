//go:build !windows

package main

import "log"

// install et uninstall : la passerelle tourne à côté de MT5, donc sous Windows.
func install(args []string) { log.Fatal("install : Windows seulement") }
func uninstall()            { log.Fatal("uninstall : Windows seulement") }
