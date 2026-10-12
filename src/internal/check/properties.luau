--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
What OpenMW's `handleProperty` and `applyDrawableProperties` do with each property on a rendered
object, and the textures a file makes OpenMW load.
]]

local Base = require './base'

type Checker = Base.Checker

local {get, is, recordType, typeName, push, isActive, checkInterpolator, hasInterpolator} = Base
local Constants = Base.constants

--- `getShaderMaterial`: shader names that are `.bgsm`/`.bgem` material files.
local function isMaterial(name: string): boolean
  local extension = string.match(string.lower(name), '%.([^%./\\]+)$')
  return extension == 'bgsm' or extension == 'bgem'
end

--- nifloader.cpp `handleTextureControllers`: only flip controllers, which always flip the base
--- texture.
local function checkTextureControllers(checker: Checker, chain: { { any } })
  for _, entry in chain do
    local controller = entry[1]
    if not isActive(entry[2]) then continue end

    if not is(checker, controller, 'NiFlipController') then
      push(
        checker,
        'broken',
        'unexpected_texture_controller',
        controller,
        `Unexpected texture controller {typeName(checker, controller)}`
      )
      continue
    end

    if not checkInterpolator(checker, controller, 'NiFloatInterpolator') then continue end

    local flip = get(checker, controller, 'NiFlipController')
    if flip and flip.texSlot ~= 0 then
      push(
        checker,
        'broken',
        'flip_controller_slot',
        controller,
        `NiFlipController targets texture slot {flip.texSlot}, but OpenMW always flips the base texture`
      )
    end
  end
end

--- nifloader.cpp `handleMaterialControllers`.
local function checkMaterialControllers(checker: Checker, chain: { { any } })
  for _, entry in chain do
    local controller = entry[1]
    if not isActive(entry[2]) then continue end

    local kind = recordType(checker, controller)
    if kind == 'NiAlphaController' then
      checkInterpolator(checker, controller, 'NiFloatInterpolator')
    elseif kind == 'NiMaterialColorController' then
      local color = get(checker, controller, 'NiMaterialColorController')
      if not color then continue end

      if color.data < 0 and not hasInterpolator(checker, controller) then continue end

      if Base.morrowindRules(checker) and color.targetColor == Constants.TargetSpecular then
        push(
          checker,
          'broken',
          'specular_color_controller',
          controller,
          'NiMaterialColorController animating specular color is skipped for Morrowind NIFs'
        )
      else
        checkInterpolator(checker, controller, 'NiPoint3Interpolator')
      end
    else
      push(
        checker,
        'broken',
        'unexpected_material_controller',
        controller,
        `Unexpected material controller {typeName(checker, controller)}`
      )
    end
  end
end

--- nifloader.cpp `getBSShaderPrefix`, `getBSLightingShaderPrefix`: shader types other than the
--- default (and No Lighting) are drawn with the default shader.
local function checkShaderType(checker: Checker, index: number)
  local shader = get(checker, index, 'BSShaderProperty')
  if not shader then return end

  local shaderType = shader.type
  local lighting = is(checker, index, 'BSLightingShaderProperty')
  local handled = if lighting then shaderType == 0 else shaderType == 1 or shaderType == 33
  if handled then return end

  local known = if lighting
    then shaderType <= 21
    else shaderType == 0
      or shaderType == 10
      or shaderType == 14
      or shaderType == 17
      or shaderType == 29
      or shaderType == 32
  push(
    checker,
    'broken',
    'unhandled_shader_type',
    index,
    `{if known then 'Unhandled' else 'Unknown'} {if lighting
      then 'BSLightingShaderType'
      else 'BSShaderType'} type {shaderType}, so it's drawn with the default shader`
  )
end

--- nifloader.cpp `handleTextureSet`: only the diffuse, normal, and glow slots are used.
local function checkTextureSet(checker: Checker, shader: number, set: any)
  local unhandled = [
    for slot, texture in enumerate(set.textures)
    if slot > Constants.TextureSetStages and texture ~= ''
    => `{slot - 1} ("{texture}")`
  ]

  if #unhandled == 0 then return end

  push(
    checker,
    'broken',
    'unhandled_texture_stage',
    shader,
    `Unhandled texture stages {table.concat(unhandled, ', ')}; only the diffuse, normal, and glow maps are used`
  )
end

--- nifloader.cpp `handleProperty` for Bethesda shaders.
local function checkShaderProperty(checker: Checker, index: number, net: any, chain: { { any } })
  local kind = recordType(checker, index)
  if kind == 'BSShaderPPLightingProperty' then
    checkShaderType(checker, index)
    local shader = get(checker, index, 'BSShaderPPLightingProperty')
    local set = if shader then get(checker, shader.textureSet, 'BSShaderTextureSet') else nil
    if set then checkTextureSet(checker, index, set) end

    checkTextureControllers(checker, chain)
  elseif kind == 'BSShaderNoLightingProperty' then
    checkShaderType(checker, index)
    checkTextureControllers(checker, chain)
  elseif kind == 'BSLightingShaderProperty' then
    -- A material file replaces the shader's own settings.
    if isMaterial(net.name) then return end

    checkShaderType(checker, index)
    local shader = get(checker, index, 'BSLightingShaderProperty')
    local set = if shader then get(checker, shader.textureSet, 'BSShaderTextureSet') else nil
    if set then checkTextureSet(checker, index, set) end

    checkTextureControllers(checker, chain)
  elseif kind == 'BSEffectShaderProperty' and not isMaterial(net.name) then
    checkTextureControllers(checker, chain)
  end
end

--- nifloader.cpp `getBlendMode`: factors 11-15 aren't blend modes, and destination alpha is
--- replaced with one.
local function checkAlpha(checker: Checker, index: number, alpha: any)
  if not bit32.btest(alpha.flags, 1) then return end

  local source = bit32.extract(alpha.flags, 1, 4)
  local destination = bit32.extract(alpha.flags, 5, 4)
  local function factor(which: string, value: number)
    if value <= 10 then return end

    push(
      checker,
      'broken',
      'unexpected_blend_mode',
      index,
      `Unexpected blend mode: {value} ({which}); SRC_ALPHA is used instead`
    )
  end

  factor('source', source)
  factor('destination', destination)
  if destination == 8 then
    push(
      checker,
      'broken',
      'destination_alpha_blend',
      index,
      'the destination blend factor is DST_ALPHA, which OpenMW replaces with ONE'
    )
  end
end

--- nifloader.cpp `handleTextureProperty`.
local function checkTexturing(checker: Checker, index: number, texturing: any, chain: { { any } })
  for slot, texture in texturing.textures do
    local zero = slot - 1
    if not (texture.enabled or (zero == 0 and #chain > 0)) then continue end

    if zero >= Constants.TextureStages then
      push(checker, 'broken', 'unhandled_texture_stage', index, `Unhandled texture stage {zero}`)
    elseif zero == 0 and texture.enabled and texture.sourceTexture < 0 and #chain == 0 then
      push(checker, 'broken', 'empty_base_texture', index, 'Base texture is in use but empty')
    end
  end

  checkTextureControllers(checker, chain)
end

--- nifloader.cpp `handleProperty` and `applyDrawableProperties`.
local function check(checker: Checker)
  local seen = {}
  local properties = checker.properties
  checker.properties = {}
  for _, index in properties do
    if seen[index] then continue end

    seen[index] = true
    local net = get(checker, index, 'NiObjectNET')
    if not net then continue end

    local chain = Base.controllers(checker, net.controller)
    local kind = recordType(checker, index)
    if kind == 'NiAlphaProperty' then
      local alpha = get(checker, index, 'NiAlphaProperty')
      if alpha then checkAlpha(checker, index, alpha) end
    elseif kind == 'NiSpecularProperty' then
      -- applyDrawableProperties: specular is always off for Morrowind-era files.
      local specular = get(checker, index, 'NiSpecularProperty')
      if Base.morrowindRules(checker) and specular and specular.enable then
        push(
          checker,
          'info',
          'specular_ignored',
          index,
          'NiSpecularProperty is ignored; Morrowind NIFs never get specular highlights in OpenMW'
        )
      end
    elseif kind == 'NiTexturingProperty' then
      local texturing = get(checker, index, 'NiTexturingProperty')
      if texturing then checkTexturing(checker, index, texturing, chain) end

      continue
    elseif kind == 'NiMaterialProperty' then
      checkMaterialControllers(checker, chain)
      continue
    elseif
      kind == 'BSShaderPPLightingProperty'
      or kind == 'BSShaderNoLightingProperty'
      or kind == 'BSLightingShaderProperty'
      or kind == 'BSEffectShaderProperty'
    then
      checkShaderProperty(checker, index, net, chain)
      continue
    elseif
      kind ~= 'NiStencilProperty'
      and kind ~= 'NiWireframeProperty'
      and kind ~= 'NiZBufferProperty'
      and kind ~= 'NiVertexColorProperty'
      and kind ~= 'NiFogProperty'
      and kind ~= 'NiShadeProperty'
      and kind ~= 'NiDitherProperty'
    then
      push(
        checker,
        'broken',
        'unhandled_property',
        index,
        `Unhandled {typeName(checker, index)}; its effect isn't drawn`
      )
      continue
    end

    for _, entry in chain do
      if isActive(entry[2]) then
        push(
          checker,
          'broken',
          'controller_does_nothing',
          entry[1],
          `{typeName(checker, entry[1])} on {typeName(checker, index)} is ignored`
        )
      end
    end
  end
end

--- nifloader.cpp `handleInternalTexture`. OpenMW numbers pixel formats as RGB, RGBA, `Palette`,
--- `PaletteAlpha`, BGR, BGRA, DXT1, DXT3, DXT5, but files number 4-9 as DXT1, DXT3, DXT5,
--- non-interleaved RGB, bump, and luma bump.
local function checkPixelData(checker: Checker, index: number, pixels: any)
  local format = pixels.pixelFormat.format
  local misread: string? = nil
  if format == 4 then
    misread = 'DXT1 as BGR'
  elseif format == 5 then
    misread = 'DXT3 as BGRA'
  elseif format == 6 then
    misread = 'DXT5 as DXT1'
  elseif format == 7 then
    misread = 'non-interleaved RGB as DXT3'
  elseif format == 8 then
    misread = 'a bump map as DXT5'
  elseif format > 3 then
    misread = 'pixel format, which it can\'t read'
  end

  if misread then
    push(
      checker,
      'broken',
      'embedded_texture_format',
      index,
      `OpenMW reads this embedded {misread}`
    )
  end

  local bitsPerPixel = pixels.pixelFormat.bitsPerPixel
  if (format == 2 or format == 3) and (pixels.palette < 0 or bitsPerPixel ~= 8) then
    push(
      checker,
      'broken',
      'invalid_palette_texture',
      index,
      'Palettized texture is invalid: it needs a palette and 8 bits per pixel'
    )
  end

  for _, mipmap in pixels.mipmaps do
    if mipmap.width == 0 or mipmap.height == 0 then
      push(
        checker,
        'broken',
        'invalid_embedded_texture',
        index,
        'Internal Texture Width and height must be non zero, ignoring texture'
      )
      break
    end

    local size = mipmap.width * mipmap.height * math.max(bitsPerPixel, 1) // 8
    if mipmap.offset + size > pixels.data.count and not misread then
      push(
        checker,
        'broken',
        'invalid_embedded_texture',
        index,
        'Internal texture\'s mipmap data out of bounds, ignoring texture'
      )
      break
    end
  end
end

--- Texture paths OpenMW loads, in file order, from reachable records: external source textures,
--- texture set slots 0-2, and the No Lighting and Effect shaders' textures (not when a material
--- file replaces them). Embedded textures are checked and counted.
local function collectTextures(checker: Checker)
  local count = #checker.records
  local materialSets = {}
  for index = 0, count - 1 do
    if not checker.reachable[index] then continue end

    local shader = get(checker, index, 'BSLightingShaderProperty')
    if shader and isMaterial(shader.name) and shader.textureSet >= 0 then
      materialSets[shader.textureSet] = true
    end
  end

  local textures = {}
  for index = 0, count - 1 do
    if not checker.reachable[index] then continue end

    local source = get(checker, index, 'NiSourceTexture')
    if source then
      if source.external ~= 0 then
        table.insert(textures, source.file)
      else
        local pixels = get(checker, source.data, 'NiPixelData')
        if pixels then
          checker.stats.embeddedTextures += 1
          checker.stats.embeddedTextureBytes += pixels.data.count
          checkPixelData(checker, source.data, pixels)
        end
      end

      continue
    end

    local set = get(checker, index, 'BSShaderTextureSet')
    if set then
      if not materialSets[index] then
        for slot = 1, math.min(#set.textures, Constants.TextureSetStages) do
          table.insert(textures, set.textures[slot])
        end
      end

      continue
    end

    local noLighting = get(checker, index, 'BSShaderNoLightingProperty')
    if noLighting then
      table.insert(textures, noLighting.filename)
      continue
    end

    local effect = get(checker, index, 'BSEffectShaderProperty')
    if effect and not isMaterial(effect.name) then table.insert(textures, effect.sourceTexture) end
  end

  local seen = {}
  for _, texture in textures do
    if texture ~= '' and not seen[texture] then
      seen[texture] = true
      table.insert(checker.textures, texture)
    end
  end
end

return table.freeze {
  check = check,
  collectTextures = collectTextures,
}
