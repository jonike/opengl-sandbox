########################################################################
############################### fancy gl ###############################
########################################################################
import opengl, glm, math, random, strutils, macros,
       sdl2, sdl2/image, sdl2/ttf, os, terminal

import fancyglpkg/[
  macroutils,
  basic_random
]

proc panic*(message: varargs[string, `$`]): void {. noreturn .} =
  ## nobody cares about exception classes
  var msg = ""
  for msgFract in message:
    msg.add msgFract
  raise newException(Exception, msg)

include fancyglpkg/etc
include fancyglpkg/glm_additions
include fancyglpkg/stopwatch
include fancyglpkg/default_setup
include fancyglpkg/shapes
include fancyglpkg/typeinfo
include fancyglpkg/samplers
include fancyglpkg/samplertypeinfo
include fancyglpkg/framebuffer
include fancyglpkg/glwrapper
include fancyglpkg/heightmap
include fancyglpkg/iqm
include fancyglpkg/camera
include fancyglpkg/sdladditions
include fancyglpkg/cameraControls
include fancyglpkg/shadingDsl
include fancyglpkg/text

export opengl, glm, sdl2, basic_random, macroutils.s
export math.arctan2

when (not defined release) and (not defined windows) and (not defined nogdbsection):
  include fancyglpkg/debug
