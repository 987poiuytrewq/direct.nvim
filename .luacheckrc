std = "luajit"
globals = { "vim" }
max_line_length = 120

files["tests/**"] = {
  globals = { "vim" },
  max_line_length = false,
}
