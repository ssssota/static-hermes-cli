function assert(condition) {
  if (!condition) throw new Error("runtime check failed");
}

assert("e\u0301".normalize("NFC") === "\u00e9");
assert("\u00e9".normalize("NFD") === "e\u0301");
assert(JSON.stringify([1, 2, 3].map(x => x * 2)) === "[2,4,6]");
try {
  throw new Error("expected");
} catch (error) {
  assert(error.message === "expected");
}
print("runtime ok");
