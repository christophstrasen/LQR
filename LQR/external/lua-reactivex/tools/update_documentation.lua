local lfs = require("lfs")
local docroc = require("tools/docroc")

io.output('doc/README.md')

io.write('# Lua-ReactiveX\n\n')

function readFile(filename)
  local file = io.open(filename, 'r')
  local text = file:read('*a')
  file:close()
  
  return text
end

function getFileListRecursive(path, rules, accumulator)
  local accumulator = accumulator or {}

  for file in lfs.dir(path) do
      if file ~= "." and file ~= ".." then
          local f = path..'/'..file
          local attr = lfs.attributes (f)
          assert (type(attr) == "table")
          if attr.mode == "directory" then
            getFileListRecursive (f, rules, accumulator)
          else
            local excluded = false

            if rules and rules.excludePatterns then
              for _, pathPattern in ipairs(rules.excludePatterns) do
                if f:match(pathPattern) then
                  excluded = true
                  break
                end
              end
            end

            if not excluded then
              if rules and rules.includePatterns then
                for _, pathPattern in ipairs(rules.includePatterns) do
                  if f:match(pathPattern) then
                    table.insert(accumulator, f)
                    break
                  end
                end
              else
                table.insert(accumulator, f)
              end
            end
          end
      end
  end

  return accumulator
end

function getContents(...)
  local fileLists = { ... }
  local contents = {}

  for k, fileList in ipairs(fileLists) do
    for k,file in ipairs(fileList) do
      table.insert(contents, readFile(file) or "")
    end
  end

  return contents
end

local observableSources = getFileListRecursive("reactivex", { includePatterns = { "observable%.lua$", "operators/.*%.lua$" } })
local restOfSources = getFileListRecursive("reactivex", { excludePatterns = { "observable%.lua$", "operators/.*%.lua$" } })
local allSourceContents = getContents(observableSources, restOfSources)
local text = table.concat(allSourceContents, "\n\n")

local comments = docroc.process_text(text)
local lastClass = ""

-- Generate table of contents
for _, comment in ipairs(comments) do
  local tags = comment.tags

  if tags.class then
    local class = tags.class[1].text
    lastClass = class
    io.write('- [' .. class .. '](#' .. class:lower() .. ')\n')
  else
    local context = comment.context:match('function.-([:%.].+)')
    if tags.arg then
      context = context:gsub('%b()', function(signature)
        local args = {}

        for _, arg in ipairs(tags.arg) do
          table.insert(args, arg.name)
        end

        return '(' .. table.concat(args, ', ') .. ')'
      end)
    end

    local name = comment.context:match('function.-[:%.]([^%(]+)')
    local functionName = comment.context:match('function.-[:.]([^(]+)')

    io.write('  - [' .. name .. '](#' .. lastClass:lower() .. "-" .. functionName:lower() .. ')\n')
  end
end

io.write('\n')

-- Generate content
for _, comment in ipairs(comments) do
  local tags = comment.tags

  if tags.class then
    lastClass = tags.class[1].text
    io.write('## ' .. tags.class[1].text .. '\n\n')
    if tags.description then
      io.write(tags.description[1].text .. '\n\n')
    end
  else
    local context = comment.context:match('function.-([:%.].+)')
    local functionName = context:match('[.:]([^(]+)')

    if tags.arg then
      context = context:gsub('%b()', function(signature)
        local args = {}

        for _, arg in ipairs(tags.arg) do
          table.insert(args, arg.name)
        end

        return '(' .. table.concat(args, ', ') .. ')'
      end)

    end

    io.write(('---\n<a name="' .. lastClass:lower() .. '-' .. functionName:lower() .. '"></a>\n### `%s`\n\n'):format(context))

    if tags.description then
      io.write(('%s\n\n'):format(tags.description[1].text))
    end

    if tags.arg then
      io.write('| Name | Type | Default | Description |\n')
      io.write('|------|------|---------|-------------|\n')

      for _, arg in ipairs(tags.arg) do
        local name = arg.name
        name = '`' .. name .. '`'
        local description = arg.description or ''
        local type = arg.type:gsub('|', ' or ')
        local default = ''
        if arg.optional then
          type = type .. ' (optional)'
          default = arg.default or default
        end
        local line = '| ' .. name .. ' | ' .. type .. ' | ' .. default .. ' | ' .. description .. ' |'
        io.write(line .. '\n')
      end

      io.write('\n')
    end
  end
end
