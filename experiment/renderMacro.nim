# TODO document current steps
# TODO frame code generation for rendering
# TODO optimization for pulling up variables into CPU
# TODO variables should not conflict with glsl keywords

# stdlib
import sugar, algorithm, macros, strutils, tables, sequtils
# packages
import ../fancygl, ast_pattern_matching
# local stuff
import normalizeType, glslTranslate, boring_stuff, std140AlignedWrite

export fancygl

export boring_stuff.zip

const persistentMappedBuffers* = false

# not exporting this results in compilation failure
# weird bug in nim
export std140AlignedWrite

static:
  let empty = newEmptyNode()

proc deduplicate(arg: var seq[NimNode]): void =
  let l = arg.len
  arg = sequtils.deduplicate(arg)
  if arg.len != l:
    echo "reomved something from", arg.repr

proc symKind(arg: NimNode): NimSymKind =
  if arg.kind == nnkHiddenDeref:
    symKind(arg[0])
  else:
    macros.symKind(arg)

proc indentCode(arg: string): string =
  result = ""
  var indentation = 0
  for line in splitLines(arg):
    indentation -= line.count("}")
    result.add "  ".repeat(max(indentation, 0))
    result.add line
    result.add "\n"
    indentation += line.count("{")

proc debugUniformBlock*(program: Program, blockIndex: GLuint): void =
  var numUniforms: GLint
  glGetActiveUniformBlockiv(program.handle, blockIndex, GL_UNIFORM_BLOCK_ACTIVE_UNIFORMS, numUniforms.addr)
  var uniforms = newSeq[GLint](numUniforms)
  glGetActiveUniformBlockiv(program.handle, blockIndex, GL_UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES, uniforms[0].addr)

  var offsets = newSeq[GLint](uniforms.len)
  glGetActiveUniformsiv(program.handle, GLsizei(uniforms.len), cast[ptr GLuint](uniforms[0].addr), GL_UNIFORM_OFFSET, offsets[0].addr )

  for i, uniformIndex in uniforms:
    var
      name: string
      newLen: GLsizei
      size: GLint
      typ: GLenum

    name.setLen(256)
    glGetActiveUniform(program.handle, GLuint(uniformIndex), GLsizei(256), newLen.addr, size.addr, typ.addr, name[0].addr)
    name.setLen newLen
    echo "  ", name, "\toffset: ", offsets[i]

proc addIfNew[T](s: var seq[T], item:T): void =
  if item notin s:
    s.add item

macro render_inner(debug: static[bool], mesh, arg: typed): untyped =

  arg.expectKind nnkDo
  arg.matchAst:
  of nnkDo(
    _,_,_,
    nnkFormalParams(
      _, `vertexDef` @ nnkIdentDefs, `glDef` @ nnkIdentDefs
    ),
    _,_,
    `body` @ nnkStmtList,
    `resultSym`
  ):
    if debug:
      echo "<render_inner>"
      #echo arg.treeRepr


    let typeInst = arg.getTypeInst

    typeInst.expectKind nnkProcTy
    typeInst[0].expectKind nnkFormalParams
    typeInst[0][1].expectKind nnkIdentDefs
    typeInst[0][2].expectKind nnkIdentDefs
    let vertexSym = typeInst[0][1][0]
    let glSym     = typeInst[0][2][0]

    let vertexPart = nnkStmtList.newTree
    let fragmentPart = nnkStmtList.newTree
    block:
      var currentNode = vertexPart
      for stmt in body:
        if stmt.kind == nnkCommentStmt and stmt.strVal == "rasterize":
          currentNode = fragmentPart
        currentNode.add stmt

    var usedProcSymbols   = newSeq[NimNode](0)
    var symCollection = newSeq[NimNode](0)
    var usedTypes = newSeq[NimNode](0)

    var uniformSamplers = newSeq[NimNode](0)
    var uniformRest = newSeq[NimNode](0)


    proc processType(node: NimNode): void =
      ## Append the normalized version of `node` to `usedTypes` if
      ## necessary.
      let normalizedType = node.normalizeType
      if not normalizedType.isBuiltIn:
        usedTypes.addIfNew normalizedType

    proc processProcSym(sym: NimNode): void =
      # TODO: this is not really correct, it only checks for names.

      let symName = sym.strVal
      let isBuiltIn = symName.isBuiltIn

      if not isBuiltIn and sym notin usedProcSymbols:
        let implBody = sym.getImpl[6]

        var localSymbols = newSeq[NimNode](0)
        implBody.recursiveNodeVisiting do (node: NimNode) -> bool:
          node.matchAst:
          of `call` @ nnkCall |= call[0].kind == nnkSym and call[0].symKind == nskProc:
            processProcSym(call[0])

          of `section` @ {nnkVarSection, nnkLetSection}:
            for sym, _ in section.fieldValuePairs:
              localSymbols.add sym
              processType(sym.getTypeInst)

          of `sym` @ nnkSym:
            if sym.symKind in {nskLet,nskVar}:
              if sym notin localSymbols:
                if sym.isSampler:
                  uniformSamplers.addIfNew sym
                else:
                  uniformRest.addIfNew sym

            elif sym.symKind == nskType:
              processType(sym)

          else:
            discard

          return true

        usedProcSymbols.add sym

    body.matchAstRecursive:
    of `sym` @ nnkSym:
      let symKind = sym.symKind
      if symKind == nskProc:
        processProcSym(sym)
      elif symKind in {nskLet, nskVar, nskForVar}:
        processType(sym.getTypeInst)
      elif symKind == nskType:
        processType(sym)
      else:
        symCollection.addIfNew sym

    # TODO unused(symCollection)

    var localSymbolsVS: seq[NimNode] = @[]
    vertexPart.matchAstRecursive:
    of `section` @ {nnkVarSection, nnkLetSection}:
      for sym, _ in section.fieldValuePairs:
        localSymbolsVS.add sym

    var attributesFromVS = newSeq[NimNode](0)
    vertexPart.matchAstRecursive:
    of `attribAccess` @ nnkDotExpr(`lhs`, `rhs`) |= lhs == vertexSym:
      attributesFromVS.addIfNew attribAccess
    of `attribAccess` @ nnkDotExpr(`lhs`, `rhs`) |= lhs == glSym:
      discard
    of `sym` @ nnkSym |= sym.symKind in {nskLet, nskVar} and sym notin localSymbolsVS:
      if sym.isSampler:
        uniformSamplers.add sym
      else:
        uniformRest.addIfNew sym
    # TODO this is O(n^2), why does sortAndUnique fail?
    attributesFromVS.deduplicate

    var localSymbolsFS: seq[NimNode] = @[]
    fragmentPart.matchAstRecursive:
    of `section` @ {nnkVarSection, nnkLetSection}:
      for sym, _ in section.fieldValuePairs:
        localSymbolsFS.add sym

    # now look for all usages of symbols from the vertex shader in the fragment shader
    # TODO optimization skip symbols declarations
    var simpleVaryings = newSeq[Nimnode](0)
    var attributesFromFS = newSeq[Nimnode](0)
    fragmentPart.matchAstRecursive:
    of `sym` @ nnkSym |= sym.symkind in {nskLet, nskVar}:
      # a symbol that is used in the fragment shader
      if sym in localSymbolsVS:
        # that is declared in the fragment sader is a varying
        simpleVaryings.add sym
      elif sym notin localSymbolsFS:
        # when it is not local to the fragment shader, it is a uniform
        if sym.isSampler:
          uniformSamplers.add sym
        else:
          uniformRest.addIfNew sym

    of `attribAccess` @ nnkDotExpr(`lhs`, `rhs`) |= lhs == glSym:
      discard
    of `attribAccess` @ nnkDotExpr(`lhs`, `rhs`) |= lhs == vertexSym:
      if attribAccess notin attributesFromFS:
        attributesFromFS.add attribAccess

    attributesFromFS.deduplicate
    simpleVaryings.deduplicate
    uniformSamplers.deduplicate
    uniformRest.deduplicate

    ## split uniforms into texture/sampler uniforms and non-texture uniforms

    var allAttributes = attributesFromVS & attributesFromFS
    allAttributes.deduplicate

    let allVaryings   = simpleVaryings & attributesFromFS

    ############################################################################
    ################################ shared code ###############################
    ############################################################################

    var sharedCode = ""

    # generate types
    sharedCode.add "// types section\n"
    for tpe in usedTypes:
      let impl = tpe.getTypeImpl
      impl.matchAst:
      of nnkObjectTy(
        nnkEmpty, nnkEmpty,
        `recList` @ nnkRecList
      ):
        sharedCode.add "struct ", tpe.repr, "{\n"
        for field,tpe in recList.fields:
          sharedCode.add tpe.glslType, " "
          sharedCode.compileToGlsl field
          sharedCode.add ";\n"
        sharedCode.add "};\n"

    # uniforms
    sharedCode.add "// uniforms section\n"
    sharedCode.add "layout(std140, binding=0) uniform dynamic_shader_data {\n"
    for uniform in uniformRest:
      sharedCode.add uniform.getTypeInst.glslType, " "
      sharedCode.compileToGlsl(uniform)
      sharedCode.add ";\n"
    sharedCode.add "};\n"
    for i, uniform in uniformSamplers:
      sharedCode.add "layout(binding=", i, ") "
      sharedCode.add "uniform ", uniform.getTypeInst.glslType, " "
      sharedCode.compileToGlsl(uniform)
      sharedCode.add ";\n"

    proc getProcImpl(procSym: NimNode): NimNode =
      ## by default the ast that you get by getImpl of the proc
      ## implementation is broken.  The actual implementation is a type
      ## syntax tree, but the formal params is an untyped ast.  This
      ## representation is pretty much useless to macros.

      let procType = procSym.getTypeInst
      result = procSym.getImpl
      result.expectKind nnkProcDef
      result[3].expectKind nnkFormalParams

      result[0] = procSym
      result[3] = procType[0]
      result[5] = newEmptyNode()

    for sym in usedProcSymbols:
      if sym.strVal != "inc":
        let impl = sym.getProcImpl
        sharedCode.compileToGlsl(impl)

    ############################################################################
    ########################## generate vertex shader ##########################
    ############################################################################

    var vertexShader   = "#version 450\n"

    vertexShader.add sharedCode

    vertexShader.add "// all attributes\n"
    for i, attrib in allAttributes:
      vertexShader.add "in layout(location=", i, ") ", attrib.getTypeInst.glslType, " in_"
      vertexShader.compileToGlsl(attrib)
      vertexShader.add ";\n"

    vertexShader.add "// all varyings\n"
    for i, varying in allVaryings:
      vertexShader.add "out layout(location=", i, ") ", varying.getTypeInst.glslType, " out_"
      vertexShader.compileToGlsl(varying)
      vertexShader.add ";\n"

    vertexShader.add "void main() {\n"

    vertexShader.add "// convert used attributes to local variables (because reasons)\n"
    for i, attrib in attributesFromVS:
      vertexShader.add attrib.getTypeInst.glslType, " "
      vertexShader.compileToGlsl(attrib)
      vertexShader.add " = in_"
      vertexShader.compileToGlsl(attrib)
      vertexShader.add ";\n"

    vertexShader.add "// glsl translation of main body\n"
    vertexShader.compileToGlsl(vertexPart)

    vertexShader.add "// forward attributes that are used in the fragment shader\n"
    for i, attrib in attributesFromFS:
      vertexShader.add "out_"
      vertexShader.compileToGlsl(attrib)
      vertexShader.add " = in_"
      vertexShader.compileToGlsl(attrib)
      vertexShader.add ";\n"

    vertexShader.add "// forward other varyings\n"
    for i, varying in simpleVaryings:
      vertexShader.add "out_"
      vertexShader.compileToGlsl(varying)
      vertexShader.add " = "
      vertexShader.compileToGlsl(varying)
      vertexShader.add ";\n"

    vertexShader.add "}\n"

    ############################################################################
    ######################### generate fragment shaders ########################
    ############################################################################

    # TODO uniform locations are incorrect, use uniform buffer.

    var fragmentShader = "#version 450\n"

    fragmentShader.add sharedCode

    fragmentShader.add "// fragment output symbols\n"
    var i = 0
    for memberSym, typeSym in resultSym.getTypeImpl.fields:
      fragmentShader.add "out layout(location=", i,") ", typeSym.glslType, " "
      fragmentShader.compileToGlsl(resultSym)
      fragmentShader.add "_"
      fragmentShader.compileToGlsl(memberSym)
      fragmentShader.add ";\n"
      i += 1

    fragmentShader.add "// all varyings\n"
    for i, varying in allVaryings:
      fragmentShader.add "in layout(location=", i, ") ", varying.getTypeInst.glslType, " in_"
      fragmentShader.compileToGlsl(varying)
      fragmentShader.add ";\n"

    fragmentShader.add "void main() {\n"
    fragmentShader.add "// convert varyings to local variables (because reasons)\n"
    for i, varying in allVaryings:
      fragmentShader.add varying.getTypeInst.glslType, " "
      fragmentShader.compileToGlsl(varying)
      fragmentShader.add " = in_"
      fragmentShader.compileToGlsl(varying)
      fragmentShader.add ";\n"

    fragmentShader.compileToGlsl(fragmentPart)
    fragmentShader.add "}\n"

    if debug:
      echo "|> vertex shader <|".center(80,'=')
      echo vertexShader.indentCode
      echo "|> fragment shader <|".center(80,'=')
      echo fragmentShader.indentCode
      echo "=".repeat(80)

    if not validateShader(vertexShader, GL_VERTEX_SHADER):
      error("vertex shader could not compile", arg)
    if not validateShader(fragmentShader, GL_FRAGMENT_SHADER):
      error("fragment shader could not compile", arg)

    ############################################################################
    ############################# generate nim code ############################
    ############################################################################


    let pipelineRecList = nnkTupleTy.newTree
    let pipelineTypeSym = genSym(nskType, "Pipeline")
    let pSym = genSym(nskVar, "p")

    let uniformBufTypeSym = genSym(nskType, "UniformBufType")

    pipelineRecList.add nnkIdentDefs.newTree( ident"program",       bindSym"Program" , empty)
    pipelineRecList.add nnkIdentDefs.newTree( ident"vao",           bindSym"VertexArrayObject" , empty)
    pipelineRecList.add nnkIdentDefs.newTree(
      ident"uniformBufferHandle", bindSym"GLuint", empty
    )
    pipelineRecList.add nnkIdentDefs.newTree(
      ident"uniformBufferData", bindSym"pointer", empty
    )
    pipelineRecList.add nnkIdentDefs.newTree(
      ident"uniformBufferSize", bindSym"GLint", empty
    )

    let uniformRecList = nnkTupleTy.newTree()

    let uniformBufTypeSection =
      nnkTypeSection.newTree(
        nnkTypeDef.newTree(
          uniformBufTypeSym,
          empty,
          uniformRecList
        )
      )

    # pipelineRecList.add nnkIdentDefs.newTree( ident"program", bindSym"Program", empty )

    let initCode = newStmtList()

    ## uniform initialization

    let drawCode = newStmtList()

    if uniformRest.len > 0:
      let uniformObjectSym = genSym(nskVar, "uniformObject")

      initCode.add quote do:
        # this is not the binding index
        let uniformBlockIndex = glGetUniformBlockIndex(`pSym`.program.handle, "dynamic_shader_data");
        doAssert uniformBlockIndex != GL_INVALID_INDEX
        var blockSize: GLint
        glGetActiveUniformBlockiv(`pSym`.program.handle, uniformBlockIndex, GL_UNIFORM_BLOCK_DATA_SIZE, blockSize.addr)
        assert blockSize > 0
        `pSym`.uniformBufferSize = blockSize

        glCreateBuffers(1, `pSym`.uniformBufferHandle.addr)

        when persistentMappedBuffers:
          glNamedBufferStorage(
            `pSym`.uniformBufferHandle, GLsizei(blockSize), nil,
            GL_MAP_WRITE_BIT or GL_MAP_PERSISTENT_BIT
          )
          `pSym`.uniformBufferData = glMapNamedBufferRange(
            `pSym`.uniformBufferHandle, 0, blockSize,
            GL_MAP_WRITE_BIT or GL_MAP_PERSISTENT_BIT or GL_MAP_FLUSH_EXPLICIT_BIT
          )
        else:
          glNamedBufferStorage(`pSym`.uniformBufferHandle, GLsizei(blockSize), nil, GL_DYNAMIC_STORAGE_BIT)
          `pSym`.uniformBufferData = alloc(blockSize)


      drawCode.add quote do:
        var `uniformObjectSym`: `uniformBufTypeSym`

      for uniform in uniformRest:
        let uniformIdent = ident(uniform.strVal)

        #let typeExprA = uniform.getTypeInst
        let typeExprB = newCall(bindSym"type", uniform)

        uniformRecList.add nnkIdentDefs.newTree(
          uniformIdent,
          typeExprB,
          empty,
        )

        drawCode.add quote do:
          `uniformObjectSym`.`uniformIdent` = `uniform`

      drawCode.add quote do:
        discard std140AlignedWrite(`pSym`.uniformBufferData, 0, `uniformObjectSym`)
        when persistentMappedBuffers:
          glFlushMappedNamedBufferRange(`pSym`.uniformBufferHandle, 0, `pSym`.uniformBufferSize)
        else:
          glNamedBufferSubData(`pSym`.uniformBufferHandle, 0, `pSym`.uniformBufferSize, `pSym`.uniformBufferData)
        glBindBufferBase(GL_UNIFORM_BUFFER, 0, `pSym`.uniformBufferHandle)

    let bindTexturesCall = newCall(bindSym"bindTextures", newLit(0) )
    for sampler in uniformSamplers:
      bindTexturesCall.add sampler

    drawCode.add bindTexturesCall

    ## attribute initialization

    let attribPipelineBuffer = newSeq[NimNode](0)

    let vertexShaderLit = newLit(vertexShader)
    let fragmentShaderLit = newLit(fragmentShader)

    let lineinfoLit = newLit(body.lineinfoObj)

    if allAttributes.len > 0:
      let setBuffersCall = newCall(bindSym"setBuffers", newDotExpr(pSym, ident"vao"), newLit(0))

      for i, attrib in allAttributes:
        let iLit = newLit(uint32(i))
        let memberSym = attrib[1]

        let genType = nnkBracketExpr.newTree(
          bindSym"ArrayBufferView",
          newCall(bindSym"type", attrib.getTypeInst)
        )
        let bufferExpr = mesh.newDotExpr(ident"buffers").newDotExpr(ident(memberSym.strVal))

        # let bufferIdent = ident("buffer" & $i)
        # pipelineRecList.add nnkIdentDefs.newTree(bufferIdent, genType , empty)

        setBuffersCall.add bufferExpr

        # TODO there is no divisor inference
        let divisorLit = newLit(0) # this is a comment

        # TODO `myMeshArrayBuffer` is fake, it should work on arbitrary meshes.
        initCode.add quote do:
          #`pSym`.`bufferIdent` = myMeshArrayBuffer.view(`memberSym`)
          glEnableVertexArrayAttrib(`pSym`.vao.handle, `iLit`)
          glVertexArrayBindingDivisor(`pSym`.vao.handle, `iLit`, `divisorLit`)
          setFormat(`pSym`.vao, `iLit`, `bufferExpr`)
          glVertexArrayAttribBinding(`pSym`.vao.handle, `iLit`, `iLit`)

      drawCode.add setBuffersCall



    let pipelineTypeSection =
      nnkTypeSection.newTree(
        nnkTypeDef.newTree(
          pipelineTypeSym, empty,
          pipelineRecList
        )
      )

    result = quote do:
      `uniformBufTypeSection`
      `pipelineTypeSection`

      ## this code block should eventually be generated
      var `pSym` {.global.}: `pipelineTypeSym`

      if `pSym`.program.handle == 0:

        `pSym`.program.handle = glCreateProgram()
        `pSym`.program.attachAndDeleteShader(
          compileShader(GL_VERTEX_SHADER, `vertexShaderLit`, `lineinfoLit`))
        `pSym`.program.attachAndDeleteShader(
          compileShader(GL_FRAGMENT_SHADER, `fragmentShaderLit`, `lineinfoLit`))

        `pSym`.program.linkOrDelete
        # `pSym`.program.debugUniformBlock(0)

        glCreateVertexArrays(1, `pSym`.vao.handle.addr)

        `initCode`


      glVertexArrayElementBuffer(`pSym`.vao.handle, `mesh`.vertexIndices.handle)
      glUseProgram(`pSym`.program.handle)
      glBindVertexArray(`pSym`.vao.handle)

      `drawCode`

      # this could really be generic
      let numVertices = GLsizei(`mesh`.len)
      if `mesh`.vertexIndices.handle == 0:
        glDrawArrays(`mesh`.vertexIndices.mode, 0, numVertices)
      else:
        glDrawElementsBaseVertex(
          `mesh`.vertexIndices.mode,
          numVertices, `mesh`.vertexIndices.typ,
          cast[pointer](`mesh`.vertexIndices.byteOffset),
          GLint(`mesh`.vertexIndices.baseVertex))

    if debug:
      echo result.repr
      echo "</render_inner>"
      result.add quote do:
        if `mesh`.len == 0:
          echo "WARNING: mesh.len == 0"

type
  VertexIndexBuffer* = object
    ## This is like ElementArrayBuffer, but it does not store at
    ## compile time the type of the elements.  The type is stored as a
    ## member in the field `typ`.
    handle*: GLuint
    mode*: GLenum
    typ*: GLenum
    baseVertex*:  int
    baseIndex*:   int
    numVertices*: int

proc elementsByteOffset*(arg: VertexIndexBuffer): int =
  if arg.typ == GL_UNSIGNED_SHORT:
    return 2
  if arg.typ == GL_UNSIGNED_INT:
    return 4
  if arg.typ == GL_UNSIGNED_BYTE:
    return 1
  assert(false, "illegal element type: " & $arg.typ)

proc byteOffset*(arg: VertexIndexBuffer): int =
  arg.baseIndex * arg.elementsByteOffset

converter toVertexIndexBuffer*[T](arg: ElementArrayBuffer[T]): VertexIndexBuffer =
  result.handle      = arg.handle
  result.typ         = indexTypeTag(T)
  result.mode        = GL_POINTS
  result.numVertices = arg.len

template `or`(a,b: NimNode): NimNode =
  let arg = a
  if arg.kind != nnkEmpty:
    arg
  else:
    b

macro genMeshType*(name: untyped; vertexType: typed): untyped =
  ## expects a symbol to a vertex type. ``name`` will be the name of the new type.
  ## generates a flexible mesh type for a given vertex type.
  ##
  ## .. code-block:: nim
  ##     genMeshType(MyMesh, MyVertexType)

  let impl =
    if vertexType.kind == nnkTupleTy:
      vertexType
    else:
      vertexType.expectKind(nnkSym)
      if vertexType.symKind != nskType:
        error("not a type symbol: ", vertexType)

      let typeDef = vertexType.getImpl
      typeDef[2].expectKind nnkTupleTy
      typeDef[2]

  let bufferTuple = nnkTupleTy.newTree
  for member, typ in impl.fields:
    let ident = ident(member.strVal)
    let typ2  = nnkBracketExpr.newTree(
      bindSym"ArrayBufferView", newCall(ident"type",typ)
    )
    bufferTuple.add nnkIdentDefs.newTree(
      ident, typ2, empty
    )

  result = newStmtList()

  result.add quote do:
    type
      `name` = object
        vertexIndices*: VertexIndexBuffer
        buffers*: `bufferTuple`

  result.add quote do:
    template VertexType(_: typedesc[`name`]): untyped =
      `vertexType`

    proc len*(arg: `name`): int =
      arg.vertexIndices.numVertices

# TODO mesh seq type (multimesh)

type
  Framebuffer2*[FragmentType] = object
    handle: GLuint
    size*: Vec2i

  GlEnvironment* = object
    Position*: Vec4f
    PointSize*: float32
    ClipDistance*: UncheckedArray[float32]
    FragCoord*: Vec2f
    VertexID*: int32

  DefaultFragmentType* = object
    color: Vec4f

  DefaultFramebuffer* = Framebuffer2[DefaultFragmentType]

var defaultFramebuffer : DefaultFramebuffer


proc create[FragmentType](result: var Framebuffer2[FragmentType]): void =
  glCreateFramebuffers(1, result.handle.addr)

  var depth_texture: GLuint
  glCreateTextures(GL_TEXTURE_2D, 1, depth_texture.addr)
  glTextureParameteri(depth_texture, GL_TEXTURE_MIN_FILTER, GLint(GL_NEAREST))
  glTextureParameteri(depth_texture, GL_TEXTURE_MAG_FILTER, GLint(GL_NEAREST))
  glTextureParameteri(depth_texture, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
  glTextureParameteri(depth_texture, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))
  glTextureStorage2D(depth_texture, 1, GL_DEPTH_COMPONENT24, result.size.x, result.size.y)

  glNamedFramebufferTexture(result.handle, GL_DEPTH_ATTACHMENT, depth_texture, 0)

  var fragment: FragmentType

  var i = 0
  for field in fragment.fields:
    # Build the texture that will serve as the color attachment for the framebuffer.
    var texture_attachment: GLuint
    glCreateTextures(GL_TEXTURE_2D, 1, texture_attachment.addr)
    glTextureParameteri(texture_attachment, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR));
    glTextureParameteri(texture_attachment, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR));
    glTextureParameteri(texture_attachment, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_BORDER));
    glTextureParameteri(texture_attachment, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_BORDER));
    glTextureStorage2D(texture_attachment, 1, GL_RGBA8, result.size.x, result.size.y)
    glNamedFramebufferTexture(result.handle, GL_COLOR_ATTACHMENT0 + GLenum(i), texture_attachment, 0)

    i += 1

  let status = glCheckNamedFramebufferStatus(result.handle, GL_FRAMEBUFFER)
  assert status == GL_FRAMEBUFFER_COMPLETE

proc createFramebuffer*[FragmentType](size: Vec2i): Framebuffer2[FragmentType] =
  result.size = size
  result.create


proc injectTypes(framebuffer, mesh, arg: NimNode): NimNode {.compileTime.} =
  ## Inject types to the ``render .. do: ...`` node.
  arg.expectKind(nnkDo)
  let formalParams = arg[3]
  formalParams.expectKind(nnkFormalParams)

  let vertexTypeExpr = quote do:
    `mesh`.type.VertexType

  let fragmentTypeExpr = quote do:
    `framebuffer`.type.FragmentType

  let resultType = formalParams[0] or fragmentTypeExpr
  var vertexArg, vertexType, envArg, envType: NimNode

  formalParams.matchAst:
  of nnkFormalParams(_,nnkIdentDefs(`vertexArgX`, `envArgX`,nnkEmpty,_)):
    vertexArg = vertexArgX
    vertexType = vertexTypeExpr
    envArg = envArgX
    envType = nnkVarTy.newTree(bindSym"GlEnvironment")
  of nnkFormalParams(_,nnkIdentDefs(`vertexArgX`, `vertexTypeX`, _), nnkIdentDefs(`envArgX`, `envTypeX`,_)):
    vertexArg = vertexArgX
    vertexType = vertexTypeX or vertexTypeExpr
    envArg = envArgX
    envType = envTypeX or nnkVarTy.newTree(bindSym"GlEnvironment")

  let newParams =
    nnkFormalParams.newTree(
      resultType,
      nnkIdentDefs.newTree(
        vertexArg, vertexType, empty
      ),
      nnkIdentDefs.newTree(
        envArg, envType, empty
      )
    )

  result = arg
  result[3] = newParams

macro render*[VT,FT](framebuffer: Framebuffer2[FT], mesh, arg: untyped): untyped =
  let arg = injectTypes(framebuffer, mesh, arg)
  result = quote do:
    let fb = `framebuffer`
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fb.handle)
    render_inner(false, `mesh`, `arg`)
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0)

macro render*(mesh, arg: untyped): untyped =
  let arg = injectTypes(bindSym"defaultFramebuffer", mesh, arg)
  result = quote do:
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0)
    render_inner(false, `mesh`, `arg`)

macro renderDebug*[FT](framebuffer: Framebuffer2[FT], mesh, arg: untyped): untyped =
  let arg = injectTypes(framebuffer, mesh, arg)
  result = quote do:
    let fb = `framebuffer`
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fb.handle)
    render_inner(true, `mesh`, `arg`)
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0)

macro renderDebug*(mesh, arg: untyped): untyped =
  let arg = injectTypes(bindSym"defaultFramebuffer", mesh, arg)
  result = quote do:
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0)
    render_inner(true, `mesh`, `arg`)
