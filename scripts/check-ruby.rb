# frozen_string_literal: true
#
# Ruby 语法 + ERB 可编译性检查。
#
# 单独成一个文件，而不是在 selftest.sh 里用 heredoc 喂给 `ruby -`：
# Windows 上 Ruby 从 stdin 读脚本时按**外部编码**（这里是 GBK）解码，脚本里
# 任何非 ASCII 字符都会报 `invalid multibyte char (GBK)`，看起来像是语法错误。
# 文件形式的脚本则固定按 UTF-8 解析源码，和 locale 无关。
#
# 用法：ruby scripts/check-ruby.rb

require "erb"

PLUGIN_ROOT = File.expand_path("..", __dir__)
Dir.chdir(PLUGIN_ROOT)

# Ruby 解析器的警告也要当失败。
#
# 存在的理由是一个真实的 bug：`Errors::Invalid.new(:invalid_status, status: 400,
# status: value)` 里 `status:` 写了两遍，Ruby 只发一条 warning，然后静默取后者
# —— HTTP 状态码变成了那个非法值，`render_json_error(..., status: "bogus")`
# 抛 ArgumentError 变成 500，而 i18n 的 `%{status}` 占位符拿不到值。`ruby -c`
# 说「语法没问题」，测试也不会红，因为这是合法语法。
#
# 默认情况下这些警告直接打到 stderr、和脚本输出混在一起，抓不住。覆盖
# `Warning.warn` 就能把它们收进数组 —— Ruby 2.5 起解析器警告走这条通道。
parser_warnings = []
Warning.singleton_class.prepend(
  Module.new do
    define_method(:warn) { |message, **| parser_warnings << message }
  end,
)

failures = []

ruby_files =
  (Dir.glob("{app,lib,db,config}/**/*.rb") + Dir.glob("plugin.rb"))
    .select { |file| File.file?(file) }
    .sort

ruby_files.each do |file|
  # 用 RubyVM::InstructionSequence.compile 而不是 `ruby -c`：走的是同一条语法
  # 检查路径，但能在一个进程里跑完所有文件，也不用为每个文件起一个子进程。
  RubyVM::InstructionSequence.compile(File.read(file, encoding: "UTF-8"), file, file)
rescue SyntaxError => e
  failures << "#{file}: #{e.message.lines.first.to_s.strip}"
end

parser_warnings.each { |warning| failures << warning.strip }

# ERB 单独查：`ruby -c` 读不懂 .erb，而模板里少一个 `<% end %>` 同样是启动期
# 才炸，而且报的是视图编译错误，不指向文件。
erb_files = Dir.glob("app/views/**/*.erb").select { |file| File.file?(file) }.sort

erb_files.each do |file|
  ERB.new(File.read(file, encoding: "UTF-8"), trim_mode: "-").src
rescue StandardError => e
  failures << "#{file}: #{e.class}: #{e.message}"
end

if failures.empty?
  puts "OK  #{ruby_files.size} 个 .rb 文件、#{erb_files.size} 个 .erb 模板均通过。"
  exit 0
end

failures.each { |failure| puts "FAIL #{failure}" }
exit 1
