//
//  quicksearch-test.swift
//
//  Exercises what the search panel answers besides apps: sums, unit
//  conversions and actions -- and, mostly, what it must leave alone.
//
//  Run:  cat Roost/UI/Localized.swift Roost/Launcher/QuickSearch.swift \
//            Tools/quicksearch-test.swift | swift -
//
//  The panel exists to switch apps. Every case under "leaves apps alone"
//  is a query that must produce no extra row, because an extra row above
//  Safari when somebody typed "sa" is a regression in the one thing the
//  panel is for.
//
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}
func calc(_ s: String) -> Double? { QuickSearch.calculate(s) }

print("Sums")
check("12*8+5 = 101", calc("12*8+5") == 101)
check("precedence: 2+3*4 = 14", calc("2+3*4") == 14)
check("brackets: (2+3)*4 = 20", calc("(2+3)*4") == 20)
check("power is right-associative: 2^3^2 = 512", calc("2^3^2") == 512)
check("unary minus: -3+5 = 2", calc("-3+5") == 2)
check("× and ÷ are accepted", calc("6×7") == 42 && calc("84÷2") == 42)
check("decimals", calc("0.1+0.2").map { abs($0 - 0.3) < 1e-12 } ?? false)
check("functions: sqrt(16)+1 = 5", calc("sqrt(16)+1") == 5)
check("pi", calc("2*pi").map { abs($0 - 2 * .pi) < 1e-12 } ?? false)
check("grouping commas are ignored", calc("1,000*2") == 2000)
check("modulo", calc("10%3") == 1)
check("division by zero is not an answer", calc("1/0") == nil)
check("half an expression is not an answer", calc("1+") == nil && calc("(2+3") == nil)
check("a plain number is a query, not a sum", calc("42") == nil && calc("-5") == nil)
check("an unknown function is not an answer", calc("rm(1)") == nil && calc("abc+1") == nil)
check("formatting drops trailing zeros", QuickSearch.format(101) == "101"
      && QuickSearch.format(0.5) == "0.5" && QuickSearch.format(1.0 / 3) == "0.3333333333")

print("\nUnits")
func conv(_ s: String) -> String? { QuickSearch.convert(s) }
check("5 km in miles", conv("5 km in miles") == "3.107 mi")
check("72 f to c", conv("72 f to c") == "22.222°C")
check("2 gb in mb", conv("2 gb in mb") == "2000 MB")
check("10 kg to lb", conv("10 kg to lb") == "22.046 lb")
check("units are case-insensitive", conv("5 KM in Miles") == "3.107 mi")
check("different kinds do not convert", conv("5 km in kg") == nil)
check("an unknown unit does not convert", conv("5 parsecs in km") == nil)
check("a sentence is not a conversion", conv("go to work") == nil)

print("\nActions")
check("lock finds Lock Screen", QuickSearch.Action.matching("lock") == [.lockScreen])
check("dark finds Toggle Dark Mode", QuickSearch.Action.matching("dark") == [.toggleDarkMode])
check("trash finds Empty Bin", QuickSearch.Action.matching("trash") == [.emptyBin])
check("sleep finds both sleeps", Set(QuickSearch.Action.matching("sleep")) == [.sleep, .sleepDisplay])

print("\nLeaves apps alone")
for query in ["sa", "sl", "s", "chrome", "safari", "Visual Studio Code", "1Password", "42",
              "Xcode 16", "zoom", "notes", "mail", "terminal", "slack", "docker"] {
    check("\"\(query)\" adds nothing", QuickSearch.results(for: query).isEmpty)
}

print("\nWhat a row says")
check("a sum shows the working and copies the answer",
      QuickSearch.results(for: "12*8+5") == [.answer(title: "12*8+5 = 101", copy: "101")])
check("a conversion copies only the result",
      QuickSearch.results(for: "5 km in miles") == [.answer(title: "5 km in miles = 3.107 mi", copy: "3.107 mi")])

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
