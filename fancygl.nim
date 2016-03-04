import opengl, glm, math, strutils, nre, macros, macroutils, sdl2, sdl2/image

################################################################################
#### macro utils ###############################################################
################################################################################

macro debugResult(arg: typed) : stmt =
  echo arg.repr
  arg

include glm_additions, shapes, samplers, framebuffer, glwrapper, heightmap, typeinfo

####################################################################################
#### etc ###########################################################################
####################################################################################

type ShaderParam* = tuple[name: string, gl_type: string]

const
  sourceHeader = """
#version 330
#define M_PI 3.1415926535897932384626433832795
"""

  screenTriagleVertexSource = """
#version 330

const vec4 positions[3] = vec4[](
  vec4(-1.0, -1.0, 1.0, 1.0),
  vec4( 3.0, -1.0, 1.0, 1.0),
  vec4(-1.0,  3.0, 1.0, 1.0)
);

const vec2 texCoords[3] = vec2[](
  vec2(0.0, 0.0),
  vec2(2.0, 0.0),
  vec2(0.0, 2.0)
);

out vec2 texCoord;

void main() {
  gl_Position = positions[gl_VertexID];
  texCoord = texCoords[gl_VertexID];
}
"""

proc genShaderSource(
    sourceHeader: string,
    uniforms : openArray[string],
    inParams : openArray[string], arrayLength: int,  # for geometry shader, -1 otherwise
    outParams: openArray[string],
    includes: openArray[string], mainSrc: string): string =

  result = sourceHeader

  for i, u in uniforms:
    result.add( u & ";\n" )
  for i, paramRaw in inParams:
    let param = paramRaw.replaceWord("out", "in")
    if arrayLength >= 0:
      result.add format("$1[$2];\n", param, arrayLength)
    else:
      result.add(param & ";\n")
  for param in outParams:
    result.add(param & ";\n")
  for incl in includes:
    result.add incl

  result.add("void main() {\n")
  result.add(mainSrc)
  result.add("\n}\n")


proc forwardVertexShaderSource(sourceHeader: string,
    attribNames, attribTypes : openArray[string] ): string =

  result = sourceHeader
  for i, name in attribNames:
    let tpe = attribTypes[i]
    result.add("in " & tpe & " " & name & ";\n")

  result.add("\nout VertexData {\n")
  for i, name in attribNames:
    let tpe = attribTypes[i]
    result.add(tpe & " " & name & ";\n")
  result.add("} VertexOut;\n")

  result.add("\nvoid main() {\n")
  for name in attribNames:
    result.add("VertexOut." & name & " = " & name & ";\n")
  result.add("}\n")

  echo "forwardVertexShaderSource:\n", result

proc makeAndBindBuffer[T](buffer: var ArrayBuffer[T], index: GLint) =
  if index >= 0:
    buffer.create
    buffer.bindIt
    glVertexAttribPointer(index.GLuint, attribSize(T), attribType(T), attribNormalized(T), 0, nil)

proc bindAndAttribPointer[T](buffer: ArrayBuffer[T], index: GLint) =
  if index >= 0:
    buffer.bindIt
    glVertexAttribPointer(index.GLuint, attribSize(T), attribType(T), attribNormalized(T), 0, nil)

proc makeAndBindElementBuffer[T](buffer: var ElementArraybuffer[T]) =
  buffer.create
  buffer.bindIt

proc myEnableVertexAttribArray(vao: VertexArrayObject, index: GLint, divisorval: GLuint): void =
  if index >= 0:
    vao.enableAttrib(index.GLuint)
    vao.divisor(index.GLuint, divisorval)

template renderBlockTemplate(numLocations: int, globalsBlock, linkShaderBlock, bufferCreationBlock,
               initUniformsBlock, setUniformsBlock, drawCommand: expr): stmt {. dirty .} =
  block:
    var vao {.global.}: VertexArrayObject
    var glProgram {.global.}: GLuint  = 0
    var locations {.global.}: array[numLocations, GLint]

    globalsBlock

    if glProgram == 0:

      gl_program = linkShaderBlock
      glUseProgram(gl_program)

      initUniformsBlock

      vao = newVertexArrayObject()
      vao.bindIt

      bufferCreationBlock

      glBindBuffer(GL_ARRAY_BUFFER, 0)

      nil_vao.bindIt

      glUseProgram(0)

      #for i, loc in locations:
      #  echo "location(", i, "): ", loc

    glUseProgram(gl_program)

    bindIt(vao)

    setUniformsBlock

    drawCommand

    bindIt(nil_vao)
    glUseProgram(0);

################################################################################
## Shading Dsl #################################################################
################################################################################

proc attribute[T](name: string, value: T, divisor: GLuint) : int = 0
proc attributes(args : varargs[int]) : int = 0
proc shaderArg[T](name: string, value: T): int = 0
proc uniforms(args: varargs[int]): int = 0
proc vertexOut(args: varargs[string]): int = 0
proc geometryOut(args: varargs[string]): int = 0
proc fragmentOut(args: varargs[string]): int = 0
proc vertexMain(src: string): int = 0
proc fragmentMain(src: string): int = 0
proc geometryMain(layout, src: string): int = 0
proc includes(args: varargs[int]): int = 0
proc incl(arg: string): int = 0
proc numVertices(num: GLSizei): int = 0
proc numInstances(num: GLSizei): int = 0

################################################################################
## Shading Dsl Inner ###########################################################
################################################################################

macro shadingDslInner(mode: GLenum, fragmentOutputs: static[openArray[string]], statement: varargs[int] ) : stmt =

  var numSamplers = 0
  var numLocations = 0
  var uniformsSection : seq[string] = @[]
  var initUniformsBlock = newStmtList()
  var setUniformsBlock = newStmtList()
  var attribNames = newSeq[string](0)
  var attribTypes = newSeq[string](0)
  #var attributesSection : seq[object(name:string, tpe: string)] = @[]
  var globalsBlock = newStmtList()
  var bufferCreationBlock = newStmtList()
  var vertexOutSection : seq[string] = @[]
  var geometryOutSection : seq[string] = @[]
  var fragmentOutSection : seq[string] = @[]
  for i,fragout in fragmentOutputs:
    fragmentOutSection.add format("layout(location = $1) out vec4 $2", $i, fragout)
  var includesSection : seq[string] = @[]
  var vertexMain: string
  var geometryLayout: string
  var geometryMain: string
  var fragmentMain: string
  var hasIndices = false
  var indexType: NimNode = nil
  var numVertices, numInstances: NimNode

  #### BEGIN PARSE TREE ####

  proc locations(i: int) : NimNode =
    newTree(nnkBracketExpr, !!"locations", newLit(i))

  for call in statement.items:
    call.expectKind nnkCall
    case $call[0]
    of "numVertices":
      numVertices = call[1]

    of "numInstances":
      numInstances = call[1]

    of "uniforms":
      for innerCall in call[1][1].items:
        innerCall[1].expectKind nnkStrLit
        let name = $innerCall[1]
        let value = innerCall[2]


        let (glslType, isSample) = value.glslUniformType
        let baseString = "uniform " & glslType & " " & name

        initUniformsBlock.add( newAssignment(
          locations(numLocations),
          newCall( bindSym"glGetUniformLocation", !!"glProgram", newLit(name) )
        ))

        if isSample:
          initUniformsBlock.add( newCall( bindSym"glUniform1i", locations(numLocations), newLit(numSamplers) ) )

          proc activeTexture(texture: int): void =
            glActiveTexture( (GL_TEXTURE0 + texture).GLenum )

          setUniformsBlock.add( newCall( bindSym"activeTexture", newLit(numSamplers) ) )
          setUniformsBlock.add( newCall( bindSym"bindIt", value ) )
          numSamplers += 1
        else:
          setUniformsBlock.add( newCall( bindSym"uniform", locations(numLocations), value ) )

        uniformsSection.add( baseString )

        numLocations += 1

    of "attributes":
      for innerCall in call[1][1].items:
        innerCall[1].expectKind nnkStrLit
        let name = $innerCall[1]
        let value = innerCall[2]
        let divisor: int =
          if innerCall[3].kind == nnkHiddenStdConv:
            innerCall[3][1].intVal.int
          elif innerCall[3].kind == nnkIntLit:
            innerCall[3].intVal.int
          else:
            0

        let buffername = !(name & "Buffer")

        let isAttrib = name != "indices"
        #echo "attribute ", value.glslAttribType, " ", name

        if not isAttrib:
          if hasIndices:
            error "has already indices"

          hasIndices = true

          case value.getType2[1].typeKind
          of ntyInt8, ntyUInt8:
            indexType = bindSym"GL_UNSIGNED_BYTE"
          of ntyInt16, ntyUInt16:
            indexType = bindSym"GL_UNSIGNED_SHORT"
          of ntyInt32, ntyUInt32:
            indexType = bindSym"GL_UNSIGNED_INT"
          of ntyInt, ntyUInt:
            error "int type has to be explicity sized uint8 uint16 or uint32"
          of ntyInt64, ntyUInt64:
            error "64 bit indices not supported"
          else:
            error("unknown type kind: " & $value.getType2[1].typeKind)


        template foobarTemplate( lhs, rhs, bufferType : expr ) : stmt {.dirty.} =
          var lhs {.global.}: bufferType[rhs[0].type]

        let isSeq:bool = $value.getType2[0] == "seq"

        if isSeq:
          let bufferType =
            if isAttrib:
              bindSym"ArrayBuffer"
            else:
              bindSym"ElementArrayBuffer"

          globalsBlock.add(getAst(foobarTemplate( !! buffername, value, bufferType )))

        if isAttrib:
          bufferCreationBlock.add( newAssignment(
            locations(numLocations),
            newCall( bindSym"glGetAttribLocation", !! "glProgram", newLit(name) )
          ))

          bufferCreationBlock.add(newCall(bindSym"myEnableVertexAttribArray", !!"vao", locations(numLocations), newLit(divisor)))

        if isSeq:
          if isAttrib:
            bufferCreationBlock.add(newCall(bindSym"makeAndBindBuffer",
              !! buffername,
              locations(numLocations),
            ))

          else:
            bufferCreationBlock.add(newCall(bindSym"makeAndBindElementBuffer",
              !! buffername,
            ))

          setUniformsBlock.add(newCall(bindSym"bindIt", !! buffername))
          setUniformsBlock.add(newCall(bindSym"bufferData", !! buffername, bindSym"GL_STREAM_DRAW", value))

        else:
          if isAttrib:
            bufferCreationBlock.add(newCall(bindSym"bindAndAttribPointer",
              value,
              locations(numLocations),
            ))
          else:
            bufferCreationBlock.add(newCall(bindSym"bindIt", value))

        if isAttrib:
          attribNames.add( name )
          attribTypes.add( value.glslAttribType )
          # format("in $1 $2", value.glslAttribType, name) )
          numLocations += 1

    of "vertexOut":
      #echo "vertexOut"

      for innerCall in call[1][1].items:
        vertexOutSection.add( innerCall.strVal )

    of "geometryOut":

      for innerCall in call[1][1].items:
        geometryOutSection.add( innerCall.strVal )

    of "fragmentOut":

      fragmentOutSection = @[]
      for innerCall in call[1][1].items:
        fragmentOutSection.add( innerCall.strVal )

    of "includes":

      for innerCall in call[1][1].items:
        if innerCall[1].kind == nnkSym:
          let sym = innerCall[1].symbol
          includesSection.add(sym.getImpl.strVal)


    of "vertexMain":
      vertexMain = call[1].strVal

    of "fragmentMain":
      fragmentMain = call[1].strVal

    of "geometryMain":

      geometryLayout = call[1].strVal
      geometryMain = call[2].strVal

    else:
      echo "unknownSection"
      echo call.repr


  if hasIndices and indexType == nil:
    error "has indices, but index Type was never set to anything"

  var vertexShaderSource : string

  if vertexMain == nil and geometryMain == nil:

    if vertexOutSection.len > 0:
      error "cannot create implicit screen space quad renderer with vertex out section"

    vertexShaderSource = screenTriagleVertexSource
    vertexOutSection.add("out vec2 texCoord")


  elif vertexMain == nil:
    vertexShaderSource = forwardVertexShaderSource(sourceHeader, attribNames, attribTypes)


    vertexOutSection.newSeq(attribNames.len)
    for i in 0..<attribNames.len:
       vertexOutSection[i] = format("out $1 $2", attribTypes[i], attribNames[i])

  else:
    var attributesSection = newSeq[string](attribNames.len)
    for i in 0..<attribNames.len:
       attributesSection[i] = format("in $1 $2", attribTypes[i], attribNames[i])

    vertexShaderSource = genShaderSource(sourceHeader, uniformsSection, attributesSection, -1, vertexOutSection, includesSection, vertexMain)

  var linkShaderBlock : NimNode

  if geometryMain == nil:

    let fragmentShaderSource = genShaderSource(sourceHeader, uniformsSection, vertexOutSection, -1, fragmentOutSection, includesSection, fragmentMain)

    linkShaderBlock = newCall( bindSym"linkShader",
      newCall( bindSym"compileShader", bindSym"GL_VERTEX_SHADER", newLit(vertexShaderSource) ),
      newCall( bindSym"compileShader", bindSym"GL_FRAGMENT_SHADER", newLit(fragmentShaderSource) ),
    )

  else:
    let geometryHeader = format("$1\nlayout($2) in;\n$3;\n", sourceHeader, geometryPrimitiveLayout(mode.intVal.GLenum), geometryLayout)
    let geometryShaderSource = genShaderSource(geometryHeader, uniformsSection, vertexOutSection, geometryNumVerts(mode.intVal.GLenum), geometryOutSection, includesSection, geometryMain)
    let fragmentShaderSource = genShaderSource(sourceHeader, uniformsSection, geometryOutSection, -1, fragmentOutSection, includesSection, fragmentMain)

    linkShaderBlock = newCall( bindSym"linkShader",
      newCall( bindSym"compileShader", bindSym"GL_VERTEX_SHADER", newLit(vertexShaderSource) ),
      newCall( bindSym"compileShader", bindSym"GL_GEOMETRY_SHADER", newLit(geometryShaderSource) ),
      newCall( bindSym"compileShader", bindSym"GL_FRAGMENT_SHADER", newLit(fragmentShaderSource) ),
    )



  let drawCommand =
    if hasIndices:
      if numInstances != nil:
        newCall( bindSym"glDrawElementsInstanced", mode, numVertices, indexType, newNilLit(), numInstances )
      else:
        newCall( bindSym"glDrawElements", mode, numVertices, indexType, newNilLit() )

    else:
      if numInstances != nil:
        newCall( bindSym"glDrawArraysInstanced", mode, newLit(0), numVertices, numInstances )
      else:
        newCall( bindSym"glDrawArrays", mode, newLit(0), numVertices )

  result = getAst(renderBlockTemplate(numLocations, globalsBlock, linkShaderBlock,
         bufferCreationBlock, initUniformsBlock, setUniformsBlock, drawCommand))

  # result = newCall( bindSym"debugResult", result )

################################################################################
## Shading Dsl Outer ###########################################################
################################################################################

macro shadingDsl*(mode:GLenum, statement: stmt) : stmt {.immediate.} =

  result = newCall(bindSym"shadingDslInner", mode, !! "fragmentOutputs" )
  # numVertices = result[2]
  # numInstances = result[3]

  for section in statement.items:
    section.expectKind({nnkCall, nnkAsgn})

    if section.kind == nnkAsgn:
      section.expectLen(2)
      let ident = section[0]
      ident.expectKind nnkIdent
      case $ident.ident
      of "numVertices":
        result.add( newCall(bindSym"numVertices", section[1] ) )
      of "numInstances":
        result.add( newCall(bindSym"numInstances", section[1] ) )
      else:
        error("unknown named parameter " & $ident.ident)

    elif section.kind == nnkCall:
      let ident = section[0]
      ident.expectKind nnkIdent
      let stmtList = section[1]
      stmtList.expectKind nnkStmtList

      case $ident
      of "uniforms":
        let uniformsCall = newCall(bindSym"uniforms")

        for capture in stmtList.items:
          capture.expectKind({nnkAsgn, nnkIdent})
          if capture.kind == nnkAsgn:
            capture.expectLen 2
            capture[0].expectKind nnkIdent
            uniformsCall.add( newCall(bindSym"shaderArg", newLit($capture[0]), capture[1] ) )
          elif capture.kind == nnkIdent:
            uniformsCall.add( newCall(bindSym"shaderArg",  newLit($capture), capture) )

        result.add(uniformsCall)

      of "attributes":
        let attributesCall = newCall(bindSym"attributes")

        proc handleCapture(attributesCall, capture: NimNode, divisor: int) =
          capture.expectKind({nnkAsgn, nnkIdent})
          if capture.kind == nnkAsgn:
            capture.expectLen 2
            capture[0].expectKind nnkIdent
            attributesCall.add( newCall(bindSym"attribute", newLit($capture[0]), capture[1], newLit(divisor) ) )
          elif capture.kind == nnkIdent:
            attributesCall.add( newCall(bindSym"attribute",  newLit($capture), capture, newLit(divisor)) )


        for capture in stmtList.items:
          if capture.kind == nnkCall:
            if $capture[0] == "instanceData":
              let stmtList = capture[1]
              stmtList.expectKind nnkStmtList
              for capture in stmtList.items:
                handleCapture(attributesCall, capture, 1)

            else:
              error "expected call to instanceData, but got: " & capture.repr
          else:
            handleCapture(attributesCall, capture, 0)

        result.add(attributesCall)

      of "vertexOut", "geometryOut", "fragmentOut":

        let outCall =
          case $ident
          of "vertexOut": newCall(bindSym"vertexOut")
          of "geometryOut": newCall(bindSym"geometryOut")
          of "fragmentOut": newCall(bindSym"fragmentOut")
          else: nil

        for section in stmtList.items:
          section.expectKind({nnkVarSection, nnkStrLit, nnkTripleStrLit})
          case section.kind
          of nnkVarSection:
            for def in section:
              def.expectKind nnkIdentDefs
              def[0].expectKind nnkIdent
              def[1].expectKind nnkIdent
              outCall.add format("out $2 $1", $def[0], $def[1]).newLit
          of nnkStrLit:
            outCall.add section
          of nnkTripleStrLit:
            for line in section.strVal.splitLines:
              outCall.add line.strip.newLit
          else:
            error "unreachable"


        result.add(outCall)

      of "vertexMain":
        stmtList.expectLen(1)
        stmtList[0].expectKind({nnkTripleStrLit, nnkStrLit})
        result.add( newCall(bindSym"vertexMain", stmtList[0]) )

      of "geometryMain":
        stmtList.expectLen(2)
        stmtList[0].expectKind({nnkTripleStrLit, nnkStrLit})
        stmtList[1].expectKind({nnkTripleStrLit, nnkStrLit})
        result.add( newCall(bindSym"geometryMain", stmtList[0], stmtList[1]) )

      of "fragmentMain":
        stmtList.expectLen(1)
        stmtList[0].expectKind({ nnkTripleStrLit, nnkStrLit })
        result.add( newCall(bindSym"fragmentMain", stmtList[0]) )

      of "includes":
        let includesCall = newCall(bindSym"includes")

        for statement in stmtList:
          statement.expectKind( nnkIdent )

          includesCall.add( newCall(bindSym"incl", statement) )

        result.add(includesCall)
      else:
        error("unknown section " & $ident.ident)
