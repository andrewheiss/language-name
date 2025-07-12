--[[
language-name.lua
Quarto filter to add language labels to code blocks.
Adds a label above each code block indicating its language, with optional customization with YAML metadata.
Supports both computational and non-computational code blocks! (this was tricky!)
]]

-- Store metadata at the module level
local document_metadata = { language_name = {} }


---------------------
-- Helper functions
---------------------

-- Capitalize first letter
local function capitalize(str)
  return (str:gsub("^%l", string.upper))
end

-- Get language from code block
local function get_language(block)
  if block.t == 'CodeBlock' and block.attr and block.attr.classes and block.attr.classes[1] then
    return block.attr.classes[1]
  end
  return "text"
end

-- Get language from cell div (for computational blocks)
local function get_language_from_cell(div)
  -- Recursively search for code blocks in the cell content
  local function find_code_block(blocks)
    for _, block in ipairs(blocks) do
      if block.t == 'CodeBlock' then
        return get_language(block)
      elseif block.t == 'Div' and block.content then
        local lang = find_code_block(block.content)
        if lang then
          return lang
        end
      end
    end
    return nil
  end
  
  local lang = find_code_block(div.content)
  return lang or "text"
end

-- Get label for code block
local function get_label(block)
  if block.attr and block.attr.attributes and block.attr.attributes["language-title"] then
    return block.attr.attributes["language-title"]
  end
  return capitalize(get_language(block))
end

-- Get label for cell div (for computational blocks)
local function get_label_from_cell(div)
  if div.attr and div.attr.attributes and div.attr.attributes["language-title"] then
    return div.attr.attributes["language-title"]
  end
  return capitalize(get_language_from_cell(div))
end

-- Determine if we should show the label for this block
local function should_show_label(block)
  if block.attr and block.attr.attributes then
    if block.attr.attributes["show-language"] == "true" then
      return true
    end
    if block.attr.attributes["show-language"] == "false" then
      return false
    end
  end
  return document_metadata.language_name.show_all == "true" or document_metadata.language_name["show-all"] == "true"
end

-- Determine if we should show the label for this cell div
local function should_show_label_from_cell(div)
  if div.attr and div.attr.attributes then
    if div.attr.attributes["show-language"] == "true" then
      return true
    end
    if div.attr.attributes["show-language"] == "false" then
      return false
    end
  end
  -- Only use global setting if no local setting is specified
  return document_metadata.language_name.show_all == "true" or document_metadata.language_name["show-all"] == "true"
end

-- Check if a div is a computational cell
local function is_cell(div)
  if div.t == 'Div' and div.attr and div.attr.classes then
    for _, class in ipairs(div.attr.classes) do
      if class == "cell" then
        return true
      end
    end
  end
  return false
end


--------------------
-- Metadata reader
--------------------

-- Read global options from YAML
function Meta(meta)
  if meta and meta["language-name"] then
    for key, value in pairs(meta["language-name"]) do
      local string_value = pandoc.utils.stringify(value)
      document_metadata.language_name[key] = string_value
    end
  end
  return meta
end


----------------------
-- Main filter stuff
----------------------

local label_counter = 0

function CodeBlock(block)
  -- Skip processing if this block is marked to be skipped
  if block.attr and block.attr.attributes and block.attr.attributes["language-name-skip"] == "true" then
    return block
  end

  local lang = get_language(block)
  if lang and lang ~= "text" and should_show_label(block) then
    local label = get_label(block)

    -- Add a unique class to the code block
    label_counter = label_counter + 1
    local unique_class = "lang-label-" .. label_counter

    if block.attr and block.attr.classes then
      block.attr.classes:insert(unique_class)
    end

    -- Set the content as the language name via inline CSS
    local custom_css = string.format(
      '<style>.codeblock-with-label pre.%s::before { content: %q; }</style>',
      unique_class, label
    )

    return pandoc.Div(
      {
        pandoc.RawBlock('html', custom_css),
        block
      },
      pandoc.Attr("", {"codeblock-with-label", lang})
    )
  else
    return block
  end
end


-- HOLY CRAP this is janky but it works
function Div(div)
  -- Handle computational cells
  if is_cell(div) then
    local lang = get_language_from_cell(div)
    local should_show = should_show_label_from_cell(div)
    
    if lang and lang ~= "text" then
      -- Recursively find and mark code blocks to skip CodeBlock filter processing
      local function mark_code_blocks(blocks)
        for _, block in ipairs(blocks) do
          if block.t == 'CodeBlock' then
            if not block.attr then block.attr = pandoc.Attr() end
            if not block.attr.attributes then block.attr.attributes = {} end
            block.attr.attributes["language-name-skip"] = "true"
            return true
          elseif block.t == 'Div' and block.content then
            if mark_code_blocks(block.content) then
              return true
            end
          end
        end
        return false
      end
      
      mark_code_blocks(div.content)
      
      if should_show then
        local label = get_label_from_cell(div)

        -- Recursively find and process the code block
        local function process_code_block(blocks)
          for i, block in ipairs(blocks) do
            if block.t == 'CodeBlock' then
              -- Add a unique class to the code block
              label_counter = label_counter + 1
              local unique_class = "lang-label-" .. label_counter

              if block.attr and block.attr.classes then
                block.attr.classes:insert(unique_class)
              end

              -- Set the content as the language name via inline CSS
              local custom_css = string.format(
                '<style>.codeblock-with-label pre.%s::before { content: %q; }</style>',
                unique_class, label
              )

              -- Replace the code block with a div containing the CSS and the code block
              blocks[i] = pandoc.Div(
                {
                  pandoc.RawBlock('html', custom_css),
                  block
                },
                pandoc.Attr("", {"codeblock-with-label", lang})
              )
              return true
            elseif block.t == 'Div' and block.content then
              if process_code_block(block.content) then
                return true
              end
            end
          end
          return false
        end

        process_code_block(div.content)

        -- Add a marker class to indicate this cell has been processed
        if div.attr and div.attr.classes then
          div.attr.classes:insert("language-name-processed")
        end

        return div
      end
    end
  end
  return div
end

-- Add the CSS file to the document
function Pandoc(doc)
  if quarto.doc and quarto.doc.is_format and quarto.doc.is_format("html") then
    quarto.doc.add_html_dependency({
      name = 'language-name',
      stylesheets = {'language-name.css'}
    })
  end
  return doc
end

-- Actually run everything
return {
  {Meta = Meta},
  {Div = Div},
  {CodeBlock = CodeBlock},
  {Pandoc = Pandoc}
}
