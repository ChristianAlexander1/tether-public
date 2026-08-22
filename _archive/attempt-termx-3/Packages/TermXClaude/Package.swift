// swift-tools-version: 5.10
import PackageDescription
let package=Package(name:"TermXClaude", platforms:[.iOS(.v16)], products:[.library(name:"TermXClaude",targets:["TermXClaude"])], targets:[.target(name:"TermXClaude",dependencies:[.product(name:"TermXNode",package:"TermXNode")])])
