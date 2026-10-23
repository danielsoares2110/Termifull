//
//  main.swift
//  GlassTerm
//
//  Manual NSApplication bootstrap. No nib, no storyboard, no @main:
//  the delegate is kept in a top-level `let` so ARC cannot release it out
//  from under NSApplication while the run loop is spinning.
//

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
