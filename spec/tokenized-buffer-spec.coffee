TokenizedBuffer = require '../src/tokenized-buffer'
_ = require 'underscore-plus'

describe "TokenizedBuffer", ->
  [tokenizedBuffer, buffer, changeHandler] = []

  beforeEach ->
    # enable async tokenization
    TokenizedBuffer.prototype.chunkSize = 5
    jasmine.unspy(TokenizedBuffer.prototype, 'tokenizeInBackground')

    waitsForPromise ->
      atom.packages.activatePackage('language-javascript')

  startTokenizing = (tokenizedBuffer) ->
    tokenizedBuffer.setVisible(true)

  fullyTokenize = (tokenizedBuffer) ->
    tokenizedBuffer.setVisible(true)
    advanceClock() while tokenizedBuffer.firstInvalidRow()?
    changeHandler?.reset()

  describe "when the buffer is destroyed", ->
    beforeEach ->
      buffer = atom.project.bufferForPathSync('sample.js')
      tokenizedBuffer = new TokenizedBuffer({buffer})
      startTokenizing(tokenizedBuffer)

    it "stops tokenization", ->
      tokenizedBuffer.destroy()
      spyOn(tokenizedBuffer, 'tokenizeNextChunk')
      advanceClock()
      expect(tokenizedBuffer.tokenizeNextChunk).not.toHaveBeenCalled()

  describe "when the buffer contains soft-tabs", ->
    beforeEach ->
      buffer = atom.project.bufferForPathSync('sample.js')
      tokenizedBuffer = new TokenizedBuffer({buffer})
      startTokenizing(tokenizedBuffer)
      tokenizedBuffer.on "changed", changeHandler = jasmine.createSpy('changeHandler')

    afterEach ->
      tokenizedBuffer.destroy()
      buffer.release()

    describe "on construction", ->
      it "initially creates un-tokenized screen lines, then tokenizes lines chunk at a time in the background", ->
        line0 = tokenizedBuffer.lineForScreenRow(0)
        expect(line0.tokens.length).toBe 1
        expect(line0.tokens[0]).toEqual(value: line0.text, scopes: ['source.js'])

        line11 = tokenizedBuffer.lineForScreenRow(11)
        expect(line11.tokens.length).toBe 2
        expect(line11.tokens[0]).toEqual(value: "  ", scopes: ['source.js'], isAtomic: true)
        expect(line11.tokens[1]).toEqual(value: "return sort(Array.apply(this, arguments));", scopes: ['source.js'])

        # background tokenization has not begun
        expect(tokenizedBuffer.lineForScreenRow(0).ruleStack).toBeUndefined()

        # tokenize chunk 1
        advanceClock()
        expect(tokenizedBuffer.lineForScreenRow(0).ruleStack?).toBeTruthy()
        expect(tokenizedBuffer.lineForScreenRow(4).ruleStack?).toBeTruthy()
        expect(tokenizedBuffer.lineForScreenRow(5).ruleStack?).toBeFalsy()
        expect(changeHandler).toHaveBeenCalledWith(start: 0, end: 4, delta: 0)
        changeHandler.reset()

        # tokenize chunk 2
        advanceClock()
        expect(tokenizedBuffer.lineForScreenRow(5).ruleStack?).toBeTruthy()
        expect(tokenizedBuffer.lineForScreenRow(9).ruleStack?).toBeTruthy()
        expect(tokenizedBuffer.lineForScreenRow(10).ruleStack?).toBeFalsy()
        expect(changeHandler).toHaveBeenCalledWith(start: 5, end: 9, delta: 0)
        changeHandler.reset()

        # tokenize last chunk
        advanceClock()
        expect(tokenizedBuffer.lineForScreenRow(10).ruleStack?).toBeTruthy()
        expect(tokenizedBuffer.lineForScreenRow(12).ruleStack?).toBeTruthy()
        expect(changeHandler).toHaveBeenCalledWith(start: 10, end: 12, delta: 0)

    describe "when the buffer is partially tokenized", ->
      beforeEach ->
        # tokenize chunk 1 only
        advanceClock()
        changeHandler.reset()

      describe "when there is a buffer change inside the tokenized region", ->
        describe "when lines are added", ->
          it "pushes the invalid rows down", ->
            expect(tokenizedBuffer.firstInvalidRow()).toBe 5
            buffer.insert([1, 0], '\n\n')
            changeHandler.reset()

            expect(tokenizedBuffer.firstInvalidRow()).toBe 7
            advanceClock()
            expect(changeHandler).toHaveBeenCalledWith(start: 7, end: 11, delta: 0)

        describe "when lines are removed", ->
          it "pulls the invalid rows up", ->
            expect(tokenizedBuffer.firstInvalidRow()).toBe 5
            buffer.delete([[1, 0], [3, 0]])
            changeHandler.reset()

            expect(tokenizedBuffer.firstInvalidRow()).toBe 3
            advanceClock()
            expect(changeHandler).toHaveBeenCalledWith(start: 3, end: 7, delta: 0)

        describe "when the change invalidates all the lines before the current invalid region", ->
          it "retokenizes the invalidated lines and continues into the valid region", ->
            expect(tokenizedBuffer.firstInvalidRow()).toBe 5
            buffer.insert([2, 0], '/*')
            changeHandler.reset()
            expect(tokenizedBuffer.firstInvalidRow()).toBe 3

            advanceClock()
            expect(changeHandler).toHaveBeenCalledWith(start: 3, end: 7, delta: 0)
            expect(tokenizedBuffer.firstInvalidRow()).toBe 8

      describe "when there is a buffer change surrounding an invalid row", ->
        it "pushes the invalid row to the end of the change", ->
          buffer.setTextInRange([[4, 0], [6, 0]], "\n\n\n")
          changeHandler.reset()

          expect(tokenizedBuffer.firstInvalidRow()).toBe 8
          advanceClock()

      describe "when there is a buffer change inside an invalid region", ->
        it "does not attempt to tokenize the lines in the change, and preserves the existing invalid row", ->
          expect(tokenizedBuffer.firstInvalidRow()).toBe 5
          buffer.setTextInRange([[6, 0], [7, 0]], "\n\n\n")

          expect(tokenizedBuffer.lineForScreenRow(6).ruleStack?).toBeFalsy()
          expect(tokenizedBuffer.lineForScreenRow(7).ruleStack?).toBeFalsy()

          changeHandler.reset()
          expect(tokenizedBuffer.firstInvalidRow()).toBe 5

    describe "when the buffer is fully tokenized", ->
      beforeEach ->
        fullyTokenize(tokenizedBuffer)

      describe "when there is a buffer change that is smaller than the chunk size", ->
        describe "when lines are updated, but none are added or removed", ->
          it "updates tokens to reflect the change", ->
            buffer.setTextInRange([[0, 0], [2, 0]], "foo()\n7\n")

            expect(tokenizedBuffer.lineForScreenRow(0).tokens[1]).toEqual(value: '(', scopes: ['source.js', 'meta.brace.round.js'])
            expect(tokenizedBuffer.lineForScreenRow(1).tokens[0]).toEqual(value: '7', scopes: ['source.js', 'constant.numeric.js'])
            # line 2 is unchanged
            expect(tokenizedBuffer.lineForScreenRow(2).tokens[2]).toEqual(value: 'if', scopes: ['source.js', 'keyword.control.js'])

            expect(changeHandler).toHaveBeenCalled()
            [event] = changeHandler.argsForCall[0]
            delete event.bufferChange
            expect(event).toEqual(start: 0, end: 2, delta: 0)

          describe "when the change invalidates the tokenization of subsequent lines", ->
            it "schedules the invalidated lines to be tokenized in the background", ->
              buffer.insert([5, 30], '/* */')
              changeHandler.reset()
              buffer.insert([2, 0], '/*')
              expect(tokenizedBuffer.lineForScreenRow(3).tokens[0].scopes).toEqual ['source.js']
              expect(changeHandler).toHaveBeenCalled()
              [event] = changeHandler.argsForCall[0]
              delete event.bufferChange
              expect(event).toEqual(start: 2, end: 2, delta: 0)
              changeHandler.reset()

              advanceClock()
              expect(tokenizedBuffer.lineForScreenRow(3).tokens[0].scopes).toEqual ['source.js', 'comment.block.js']
              expect(tokenizedBuffer.lineForScreenRow(4).tokens[0].scopes).toEqual ['source.js', 'comment.block.js']
              expect(tokenizedBuffer.lineForScreenRow(5).tokens[0].scopes).toEqual ['source.js', 'comment.block.js']
              expect(changeHandler).toHaveBeenCalled()
              [event] = changeHandler.argsForCall[0]
              delete event.bufferChange
              expect(event).toEqual(start: 3, end: 5, delta: 0)

          it "resumes highlighting with the state of the previous line", ->
            buffer.insert([0, 0], '/*')
            buffer.insert([5, 0], '*/')

            buffer.insert([1, 0], 'var ')
            expect(tokenizedBuffer.lineForScreenRow(1).tokens[0].scopes).toEqual ['source.js', 'comment.block.js']

        describe "when lines are both updated and removed", ->
          it "updates tokens to reflect the change", ->
            buffer.setTextInRange([[1, 0], [3, 0]], "foo()")

            # previous line 0 remains
            expect(tokenizedBuffer.lineForScreenRow(0).tokens[0]).toEqual(value: 'var', scopes: ['source.js', 'storage.modifier.js'])

            # previous line 3 should be combined with input to form line 1
            expect(tokenizedBuffer.lineForScreenRow(1).tokens[0]).toEqual(value: 'foo', scopes: ['source.js'])
            expect(tokenizedBuffer.lineForScreenRow(1).tokens[6]).toEqual(value: '=', scopes: ['source.js', 'keyword.operator.js'])

            # lines below deleted regions should be shifted upward
            expect(tokenizedBuffer.lineForScreenRow(2).tokens[2]).toEqual(value: 'while', scopes: ['source.js', 'keyword.control.js'])
            expect(tokenizedBuffer.lineForScreenRow(3).tokens[4]).toEqual(value: '=', scopes: ['source.js', 'keyword.operator.js'])
            expect(tokenizedBuffer.lineForScreenRow(4).tokens[4]).toEqual(value: '<', scopes: ['source.js', 'keyword.operator.js'])

            expect(changeHandler).toHaveBeenCalled()
            [event] = changeHandler.argsForCall[0]
            delete event.bufferChange
            expect(event).toEqual(start: 1, end: 3, delta: -2)

        describe "when the change invalidates the tokenization of subsequent lines", ->
          it "schedules the invalidated lines to be tokenized in the background", ->
            buffer.insert([5, 30], '/* */')
            changeHandler.reset()

            buffer.setTextInRange([[2, 0], [3, 0]], '/*')
            expect(tokenizedBuffer.lineForScreenRow(2).tokens[0].scopes).toEqual ['source.js', 'comment.block.js', 'punctuation.definition.comment.js']
            expect(tokenizedBuffer.lineForScreenRow(3).tokens[0].scopes).toEqual ['source.js']
            expect(changeHandler).toHaveBeenCalled()
            [event] = changeHandler.argsForCall[0]
            delete event.bufferChange
            expect(event).toEqual(start: 2, end: 3, delta: -1)
            changeHandler.reset()

            advanceClock()
            expect(tokenizedBuffer.lineForScreenRow(3).tokens[0].scopes).toEqual ['source.js', 'comment.block.js']
            expect(tokenizedBuffer.lineForScreenRow(4).tokens[0].scopes).toEqual ['source.js', 'comment.block.js']
            expect(changeHandler).toHaveBeenCalled()
            [event] = changeHandler.argsForCall[0]
            delete event.bufferChange
            expect(event).toEqual(start: 3, end: 4, delta: 0)

        describe "when lines are both updated and inserted", ->
          it "updates tokens to reflect the change", ->
            buffer.setTextInRange([[1, 0], [2, 0]], "foo()\nbar()\nbaz()\nquux()")

            # previous line 0 remains
            expect(tokenizedBuffer.lineForScreenRow(0).tokens[0]).toEqual( value: 'var', scopes: ['source.js', 'storage.modifier.js'])

            # 3 new lines inserted
            expect(tokenizedBuffer.lineForScreenRow(1).tokens[0]).toEqual(value: 'foo', scopes: ['source.js'])
            expect(tokenizedBuffer.lineForScreenRow(2).tokens[0]).toEqual(value: 'bar', scopes: ['source.js'])
            expect(tokenizedBuffer.lineForScreenRow(3).tokens[0]).toEqual(value: 'baz', scopes: ['source.js'])

            # previous line 2 is joined with quux() on line 4
            expect(tokenizedBuffer.lineForScreenRow(4).tokens[0]).toEqual(value: 'quux', scopes: ['source.js'])
            expect(tokenizedBuffer.lineForScreenRow(4).tokens[4]).toEqual(value: 'if', scopes: ['source.js', 'keyword.control.js'])

            # previous line 3 is pushed down to become line 5
            expect(tokenizedBuffer.lineForScreenRow(5).tokens[4]).toEqual(value: '=', scopes: ['source.js', 'keyword.operator.js'])

            expect(changeHandler).toHaveBeenCalled()
            [event] = changeHandler.argsForCall[0]
            delete event.bufferChange
            expect(event).toEqual(start: 1, end: 2, delta: 2)

        describe "when the change invalidates the tokenization of subsequent lines", ->
          it "schedules the invalidated lines to be tokenized in the background", ->
            buffer.insert([5, 30], '/* */')
            changeHandler.reset()

            buffer.insert([2, 0], '/*\nabcde\nabcder')
            expect(changeHandler).toHaveBeenCalled()
            [event] = changeHandler.argsForCall[0]
            delete event.bufferChange
            expect(event).toEqual(start: 2, end: 2, delta: 2)
            expect(tokenizedBuffer.lineForScreenRow(2).tokens[0].scopes).toEqual ['source.js', 'comment.block.js', 'punctuation.definition.comment.js']
            expect(tokenizedBuffer.lineForScreenRow(3).tokens[0].scopes).toEqual ['source.js', 'comment.block.js']
            expect(tokenizedBuffer.lineForScreenRow(4).tokens[0].scopes).toEqual ['source.js', 'comment.block.js']
            expect(tokenizedBuffer.lineForScreenRow(5).tokens[0].scopes).toEqual ['source.js']
            changeHandler.reset()

            advanceClock() # tokenize invalidated lines in background
            expect(tokenizedBuffer.lineForScreenRow(5).tokens[0].scopes).toEqual ['source.js', 'comment.block.js']
            expect(tokenizedBuffer.lineForScreenRow(6).tokens[0].scopes).toEqual ['source.js', 'comment.block.js']
            expect(tokenizedBuffer.lineForScreenRow(7).tokens[0].scopes).toEqual ['source.js', 'comment.block.js']
            expect(tokenizedBuffer.lineForScreenRow(8).tokens[0].scopes).not.toBe ['source.js', 'comment.block.js']

            expect(changeHandler).toHaveBeenCalled()
            [event] = changeHandler.argsForCall[0]
            delete event.bufferChange
            expect(event).toEqual(start: 5, end: 7, delta: 0)

      describe "when there is an insertion that is larger than the chunk size", ->
        it "tokenizes the initial chunk synchronously, then tokenizes the remaining lines in the background", ->
          commentBlock = _.multiplyString("// a comment\n", tokenizedBuffer.chunkSize + 2)
          buffer.insert([0,0], commentBlock)
          expect(tokenizedBuffer.lineForScreenRow(0).ruleStack?).toBeTruthy()
          expect(tokenizedBuffer.lineForScreenRow(4).ruleStack?).toBeTruthy()
          expect(tokenizedBuffer.lineForScreenRow(5).ruleStack?).toBeFalsy()

          advanceClock()
          expect(tokenizedBuffer.lineForScreenRow(5).ruleStack?).toBeTruthy()
          expect(tokenizedBuffer.lineForScreenRow(6).ruleStack?).toBeTruthy()

      describe ".findOpeningBracket(closingBufferPosition)", ->
        it "returns the position of the matching bracket, skipping any nested brackets", ->
          expect(tokenizedBuffer.findOpeningBracket([9, 2])).toEqual [1, 29]

      describe ".findClosingBracket(startBufferPosition)", ->
        it "returns the position of the matching bracket, skipping any nested brackets", ->
          expect(tokenizedBuffer.findClosingBracket([1, 29])).toEqual [9, 2]

      it "tokenizes leading whitespace based on the new tab length", ->
        expect(tokenizedBuffer.lineForScreenRow(5).tokens[0].isAtomic).toBeTruthy()
        expect(tokenizedBuffer.lineForScreenRow(5).tokens[0].value).toBe "  "
        expect(tokenizedBuffer.lineForScreenRow(5).tokens[1].isAtomic).toBeTruthy()
        expect(tokenizedBuffer.lineForScreenRow(5).tokens[1].value).toBe "  "

        tokenizedBuffer.setTabLength(4)
        fullyTokenize(tokenizedBuffer)

        expect(tokenizedBuffer.lineForScreenRow(5).tokens[0].isAtomic).toBeTruthy()
        expect(tokenizedBuffer.lineForScreenRow(5).tokens[0].value).toBe "    "
        expect(tokenizedBuffer.lineForScreenRow(5).tokens[1].isAtomic).toBeFalsy()
        expect(tokenizedBuffer.lineForScreenRow(5).tokens[1].value).toBe "  current "

  describe "when the buffer contains hard-tabs", ->
    beforeEach ->
      waitsForPromise ->
        atom.packages.activatePackage('language-coffee-script')

      runs ->
        buffer = atom.project.bufferForPathSync('sample-with-tabs.coffee')
        tokenizedBuffer = new TokenizedBuffer({buffer})
        startTokenizing(tokenizedBuffer)

    afterEach ->
      tokenizedBuffer.destroy()
      buffer.release()

    describe "when the buffer is fully tokenized", ->
      beforeEach ->
        fullyTokenize(tokenizedBuffer)

      it "renders each tab as its own atomic token with a value of size tabLength", ->
        tabAsSpaces = _.multiplyString(' ', tokenizedBuffer.getTabLength())
        screenLine0 = tokenizedBuffer.lineForScreenRow(0)
        expect(screenLine0.text).toBe "# Econ 101#{tabAsSpaces}"
        { tokens } = screenLine0

        expect(tokens.length).toBe 4
        expect(tokens[0].value).toBe "#"
        expect(tokens[1].value).toBe " Econ 101"
        expect(tokens[2].value).toBe tabAsSpaces
        expect(tokens[2].scopes).toEqual tokens[1].scopes
        expect(tokens[2].isAtomic).toBeTruthy()
        expect(tokens[3].value).toBe ""

        expect(tokenizedBuffer.lineForScreenRow(2).text).toBe "#{tabAsSpaces} buy()#{tabAsSpaces}while supply > demand"

      it "aligns the hard tabs to the correct tab stop column", ->
        buffer.setText """
          1\t2 \t3\t4
          12\t3  \t4\t5
          123\t4   \t5\t6
        """

        tokenizedBuffer.setTabLength(4)
        fullyTokenize(tokenizedBuffer)

        expect(tokenizedBuffer.lineForScreenRow(0).text).toBe "1   2   3   4"
        expect(tokenizedBuffer.lineForScreenRow(0).tokens[1].bufferDelta).toBe 1
        expect(tokenizedBuffer.lineForScreenRow(0).tokens[1].screenDelta).toBe 3

        expect(tokenizedBuffer.lineForScreenRow(1).text).toBe "12  3   4   5"
        expect(tokenizedBuffer.lineForScreenRow(1).tokens[1].bufferDelta).toBe 1
        expect(tokenizedBuffer.lineForScreenRow(1).tokens[1].screenDelta).toBe 2

        expect(tokenizedBuffer.lineForScreenRow(2).text).toBe "123 4       5   6"
        expect(tokenizedBuffer.lineForScreenRow(2).tokens[1].bufferDelta).toBe 1
        expect(tokenizedBuffer.lineForScreenRow(2).tokens[1].screenDelta).toBe 1

        tokenizedBuffer.setTabLength(3)
        fullyTokenize(tokenizedBuffer)

        expect(tokenizedBuffer.lineForScreenRow(0).text).toBe "1  2  3  4"
        expect(tokenizedBuffer.lineForScreenRow(0).tokens[1].bufferDelta).toBe 1
        expect(tokenizedBuffer.lineForScreenRow(0).tokens[1].screenDelta).toBe 2

        expect(tokenizedBuffer.lineForScreenRow(1).text).toBe "12 3     4  5"
        expect(tokenizedBuffer.lineForScreenRow(1).tokens[1].bufferDelta).toBe 1
        expect(tokenizedBuffer.lineForScreenRow(1).tokens[1].screenDelta).toBe 1

        expect(tokenizedBuffer.lineForScreenRow(2).text).toBe "123   4     5  6"
        expect(tokenizedBuffer.lineForScreenRow(2).tokens[1].bufferDelta).toBe 1
        expect(tokenizedBuffer.lineForScreenRow(2).tokens[1].screenDelta).toBe 3

        tokenizedBuffer.setTabLength(2)
        fullyTokenize(tokenizedBuffer)

        expect(tokenizedBuffer.lineForScreenRow(0).text).toBe "1 2   3 4"
        expect(tokenizedBuffer.lineForScreenRow(0).tokens[1].bufferDelta).toBe 1
        expect(tokenizedBuffer.lineForScreenRow(0).tokens[1].screenDelta).toBe 1

        expect(tokenizedBuffer.lineForScreenRow(1).text).toBe "12  3   4 5"
        expect(tokenizedBuffer.lineForScreenRow(1).tokens[1].bufferDelta).toBe 1
        expect(tokenizedBuffer.lineForScreenRow(1).tokens[1].screenDelta).toBe 2

        expect(tokenizedBuffer.lineForScreenRow(2).text).toBe "123 4     5 6"
        expect(tokenizedBuffer.lineForScreenRow(2).tokens[1].bufferDelta).toBe 1
        expect(tokenizedBuffer.lineForScreenRow(2).tokens[1].screenDelta).toBe 1

        tokenizedBuffer.setTabLength(1)
        fullyTokenize(tokenizedBuffer)

        expect(tokenizedBuffer.lineForScreenRow(0).text).toBe "1 2  3 4"
        expect(tokenizedBuffer.lineForScreenRow(0).tokens[1].bufferDelta).toBe 1
        expect(tokenizedBuffer.lineForScreenRow(0).tokens[1].screenDelta).toBe 1

        expect(tokenizedBuffer.lineForScreenRow(1).text).toBe "12 3   4 5"
        expect(tokenizedBuffer.lineForScreenRow(1).tokens[1].bufferDelta).toBe 1
        expect(tokenizedBuffer.lineForScreenRow(1).tokens[1].screenDelta).toBe 1

        expect(tokenizedBuffer.lineForScreenRow(2).text).toBe "123 4    5 6"
        expect(tokenizedBuffer.lineForScreenRow(2).tokens[1].bufferDelta).toBe 1
        expect(tokenizedBuffer.lineForScreenRow(2).tokens[1].screenDelta).toBe 1

  describe "when the buffer contains UTF-8 surrogate pairs", ->
    beforeEach ->
      waitsForPromise ->
        atom.packages.activatePackage('language-javascript')

      runs ->
        buffer = atom.project.bufferForPathSync 'sample-with-pairs.js'
        buffer.setText """
          'abc\uD835\uDF97def'
          //\uD835\uDF97xyz
        """
        tokenizedBuffer = new TokenizedBuffer({buffer})
        fullyTokenize(tokenizedBuffer)

    afterEach ->
      tokenizedBuffer.destroy()
      buffer.release()

    it "renders each UTF-8 surrogate pair as its own atomic token", ->
      screenLine0 = tokenizedBuffer.lineForScreenRow(0)
      expect(screenLine0.text).toBe "'abc\uD835\uDF97def'"
      { tokens } = screenLine0

      expect(tokens.length).toBe 5
      expect(tokens[0].value).toBe "'"
      expect(tokens[1].value).toBe "abc"
      expect(tokens[2].value).toBe "\uD835\uDF97"
      expect(tokens[2].isAtomic).toBeTruthy()
      expect(tokens[3].value).toBe "def"
      expect(tokens[4].value).toBe "'"

      screenLine1 = tokenizedBuffer.lineForScreenRow(1)
      expect(screenLine1.text).toBe "//\uD835\uDF97xyz"
      { tokens } = screenLine1

      expect(tokens.length).toBe 4
      expect(tokens[0].value).toBe '//'
      expect(tokens[1].value).toBe '\uD835\uDF97'
      expect(tokens[1].value).toBeTruthy()
      expect(tokens[2].value).toBe 'xyz'
      expect(tokens[3].value).toBe ''

  describe "when the grammar is tokenized", ->
    it "emits the `tokenized` event", ->
      editor = null
      tokenizedHandler = jasmine.createSpy("tokenized handler")

      waitsForPromise ->
        atom.project.open('sample.js').then (o) -> editor = o

      runs ->
        tokenizedBuffer = editor.displayBuffer.tokenizedBuffer
        tokenizedBuffer.on 'tokenized', tokenizedHandler
        fullyTokenize(tokenizedBuffer)
        expect(tokenizedHandler.callCount).toBe(1)

    it "doesn't re-emit the `tokenized` event when it is re-tokenized", ->
      editor = null
      tokenizedHandler = jasmine.createSpy("tokenized handler")

      waitsForPromise ->
        atom.project.open('sample.js').then (o) -> editor = o

      runs ->
        tokenizedBuffer = editor.displayBuffer.tokenizedBuffer
        fullyTokenize(tokenizedBuffer)

        tokenizedBuffer.on 'tokenized', tokenizedHandler
        editor.getBuffer().insert([0, 0], "'")
        fullyTokenize(tokenizedBuffer)
        expect(tokenizedHandler).not.toHaveBeenCalled()

  describe "when the grammar is updated because a grammar it includes is activated", ->
    it "re-emits the `tokenized` event", ->
      editor = null
      tokenizedBuffer = null
      tokenizedHandler = jasmine.createSpy("tokenized handler")

      waitsForPromise ->
        atom.project.open('coffee.coffee').then (o) -> editor = o

      runs ->
        tokenizedBuffer = editor.displayBuffer.tokenizedBuffer
        tokenizedBuffer.on 'tokenized', tokenizedHandler
        fullyTokenize(tokenizedBuffer)
        tokenizedHandler.reset()

      waitsForPromise ->
        atom.packages.activatePackage('language-coffee-script')

      runs ->
        fullyTokenize(tokenizedBuffer)
        expect(tokenizedHandler.callCount).toBe(1)

    it "retokenizes the buffer", ->

      waitsForPromise ->
        atom.packages.activatePackage('language-ruby-on-rails')

      waitsForPromise ->
        atom.packages.activatePackage('language-ruby')

      runs ->
        buffer = atom.project.bufferForPathSync()
        buffer.setText "<div class='name'><%= User.find(2).full_name %></div>"
        tokenizedBuffer = new TokenizedBuffer({buffer})
        tokenizedBuffer.setGrammar(atom.syntax.selectGrammar('test.erb'))
        fullyTokenize(tokenizedBuffer)

        {tokens} = tokenizedBuffer.lineForScreenRow(0)
        expect(tokens[0]).toEqual value: "<div class='name'>", scopes: ["text.html.ruby"]

      waitsForPromise ->
        atom.packages.activatePackage('language-html')

      runs ->
        fullyTokenize(tokenizedBuffer)
        {tokens} = tokenizedBuffer.lineForScreenRow(0)
        expect(tokens[0]).toEqual value: '<', scopes: ["text.html.ruby","meta.tag.block.any.html","punctuation.definition.tag.begin.html"]

  describe ".tokenForPosition(position)", ->
    afterEach ->
      tokenizedBuffer.destroy()
      buffer.release()

    it "returns the correct token (regression)", ->
      buffer = atom.project.bufferForPathSync('sample.js')
      tokenizedBuffer = new TokenizedBuffer({buffer})
      fullyTokenize(tokenizedBuffer)
      expect(tokenizedBuffer.tokenForPosition([1,0]).scopes).toEqual ["source.js"]
      expect(tokenizedBuffer.tokenForPosition([1,1]).scopes).toEqual ["source.js"]
      expect(tokenizedBuffer.tokenForPosition([1,2]).scopes).toEqual ["source.js", "storage.modifier.js"]

  describe ".bufferRangeForScopeAtPosition(selector, position)", ->
    beforeEach ->
      buffer = atom.project.bufferForPathSync('sample.js')
      tokenizedBuffer = new TokenizedBuffer({buffer})
      fullyTokenize(tokenizedBuffer)

    describe "when the selector does not match the token at the position", ->
      it "returns a falsy value", ->
        expect(tokenizedBuffer.bufferRangeForScopeAtPosition('.bogus', [0, 1])).toBeFalsy()

    describe "when the selector matches a single token at the position", ->
      it "returns the range covered by the token", ->
        expect(tokenizedBuffer.bufferRangeForScopeAtPosition('.storage.modifier.js', [0, 1])).toEqual [[0, 0], [0, 3]]

    describe "when the selector matches a run of multiple tokens at the position", ->
      it "returns the range covered by all contigous tokens (within a single line)", ->
        expect(tokenizedBuffer.bufferRangeForScopeAtPosition('.function', [1, 18])).toEqual [[1, 6], [1, 28]]

  describe "when the editor.tabLength config value changes", ->
    it "updates the tab length of the tokenized lines", ->
      buffer = atom.project.bufferForPathSync('sample.js')
      buffer.setText('\ttest')
      tokenizedBuffer = new TokenizedBuffer({buffer})
      fullyTokenize(tokenizedBuffer)
      expect(tokenizedBuffer.tokenForPosition([0,0]).value).toBe '  '
      atom.config.set('editor.tabLength', 6)
      expect(tokenizedBuffer.tokenForPosition([0,0]).value).toBe '      '

    it "does not allow the tab length to be less than 1", ->
      buffer = atom.project.bufferForPathSync('sample.js')
      buffer.setText('\ttest')
      tokenizedBuffer = new TokenizedBuffer({buffer})
      fullyTokenize(tokenizedBuffer)
      expect(tokenizedBuffer.tokenForPosition([0,0]).value).toBe '  '
      atom.config.set('editor.tabLength', 1)
      expect(tokenizedBuffer.tokenForPosition([0,0]).value).toBe ' '
      atom.config.set('editor.tabLength', 0)
      expect(tokenizedBuffer.tokenForPosition([0,0]).value).toBe '  '

  describe "leading and trailing whitespace", ->
    beforeEach ->
      buffer = atom.project.bufferForPathSync('sample.js')
      tokenizedBuffer = new TokenizedBuffer({buffer})
      fullyTokenize(tokenizedBuffer)

    it "sets ::hasLeadingWhitespace to true on tokens that have leading whitespace", ->
      expect(tokenizedBuffer.lineForScreenRow(0).tokens[0].hasLeadingWhitespace).toBe false
      expect(tokenizedBuffer.lineForScreenRow(1).tokens[0].hasLeadingWhitespace).toBe true
      expect(tokenizedBuffer.lineForScreenRow(1).tokens[1].hasLeadingWhitespace).toBe false
      expect(tokenizedBuffer.lineForScreenRow(2).tokens[0].hasLeadingWhitespace).toBe true
      expect(tokenizedBuffer.lineForScreenRow(2).tokens[1].hasLeadingWhitespace).toBe true
      expect(tokenizedBuffer.lineForScreenRow(2).tokens[2].hasLeadingWhitespace).toBe false

      # The 4th token *has* leading whitespace, but isn't entirely whitespace
      buffer.insert([5, 0], ' ')
      expect(tokenizedBuffer.lineForScreenRow(5).tokens[3].hasLeadingWhitespace).toBe true
      expect(tokenizedBuffer.lineForScreenRow(5).tokens[4].hasLeadingWhitespace).toBe false

      # Lines that are *only* whitespace are not considered to have leading whitespace
      buffer.insert([10, 0], '  ')
      expect(tokenizedBuffer.lineForScreenRow(10).tokens[0].hasLeadingWhitespace).toBe false

    it "sets ::hasTrailingWhitespace to true on tokens that have trailing whitespace", ->
      buffer.insert([0, Infinity], '  ')
      expect(tokenizedBuffer.lineForScreenRow(0).tokens[11].hasTrailingWhitespace).toBe false
      expect(tokenizedBuffer.lineForScreenRow(0).tokens[12].hasTrailingWhitespace).toBe true

      # The last token *has* trailing whitespace, but isn't entirely whitespace
      buffer.setTextInRange([[2, 39], [2, 40]], '  ')
      expect(tokenizedBuffer.lineForScreenRow(2).tokens[14].hasTrailingWhitespace).toBe false
      expect(tokenizedBuffer.lineForScreenRow(2).tokens[15].hasTrailingWhitespace).toBe true

      # Lines that are *only* whitespace are considered to have trailing whitespace
      buffer.insert([10, 0], '  ')
      expect(tokenizedBuffer.lineForScreenRow(10).tokens[0].hasTrailingWhitespace).toBe true

    it "only marks trailing whitespace on the last segment of a soft-wrapped line", ->
      buffer.insert([0, Infinity], '  ')
      tokenizedLine = tokenizedBuffer.lineForScreenRow(0)
      [segment1, segment2] = tokenizedLine.softWrapAt(16)
      expect(segment1.tokens[5].value).toBe ' '
      expect(segment1.tokens[5].hasTrailingWhitespace).toBe false
      expect(segment2.tokens[6].value).toBe '  '
      expect(segment2.tokens[6].hasTrailingWhitespace).toBe true

  describe "indent level", ->
    beforeEach ->
      buffer = atom.project.bufferForPathSync('sample.js')
      tokenizedBuffer = new TokenizedBuffer({buffer})
      fullyTokenize(tokenizedBuffer)

    describe "when the line is non-empty", ->
      it "has an indent level based on the leading whitespace on the line", ->
        expect(tokenizedBuffer.lineForScreenRow(0).indentLevel).toBe 0
        expect(tokenizedBuffer.lineForScreenRow(1).indentLevel).toBe 1
        expect(tokenizedBuffer.lineForScreenRow(2).indentLevel).toBe 2
        buffer.insert([2, 0], ' ')
        expect(tokenizedBuffer.lineForScreenRow(2).indentLevel).toBe 2.5

    describe "when the line is empty", ->
      it "assumes the indentation level of the first non-empty line below or above if one exists", ->
        buffer.insert([12, 0], '    ')
        buffer.insert([12, Infinity], '\n\n')
        expect(tokenizedBuffer.lineForScreenRow(13).indentLevel).toBe 2
        expect(tokenizedBuffer.lineForScreenRow(14).indentLevel).toBe 2

        buffer.insert([1, Infinity], '\n\n')
        expect(tokenizedBuffer.lineForScreenRow(2).indentLevel).toBe 2
        expect(tokenizedBuffer.lineForScreenRow(3).indentLevel).toBe 2

        buffer.setText('\n\n\n')
        expect(tokenizedBuffer.lineForScreenRow(1).indentLevel).toBe 0

    describe "when the changed lines are surrounded by whitespace-only lines", ->
      it "updates the indentLevel of empty lines that precede the change", ->
        expect(tokenizedBuffer.lineForScreenRow(12).indentLevel).toBe 0

        buffer.insert([12, 0], '\n')
        buffer.insert([13, 0], '  ')
        expect(tokenizedBuffer.lineForScreenRow(12).indentLevel).toBe 1

      it "updates empty line indent guides when the empty line is the last line", ->
        buffer.insert([12, 2], '\n')

        # The newline and he tab need to be in two different operations to surface the bug
        buffer.insert([12, 0], '  ')
        expect(tokenizedBuffer.lineForScreenRow(13).indentLevel).toBe 1

        buffer.insert([12, 0], '  ')
        expect(tokenizedBuffer.lineForScreenRow(13).indentLevel).toBe 2
        expect(tokenizedBuffer.lineForScreenRow(14)).not.toBeDefined()

      it "updates the indentLevel of empty lines surrounding a change that inserts lines", ->
        # create some new lines
        buffer.insert([7, 0], '\n\n')
        buffer.insert([5, 0], '\n\n')

        expect(tokenizedBuffer.lineForScreenRow(5).indentLevel).toBe 3
        expect(tokenizedBuffer.lineForScreenRow(6).indentLevel).toBe 3
        expect(tokenizedBuffer.lineForScreenRow(9).indentLevel).toBe 2
        expect(tokenizedBuffer.lineForScreenRow(10).indentLevel).toBe 2
        expect(tokenizedBuffer.lineForScreenRow(11).indentLevel).toBe 2

        tokenizedBuffer.on "changed", changeHandler = jasmine.createSpy('changeHandler')

        buffer.setTextInRange([[7, 0], [8, 65]], '        one\n        two\n        three\n        four')

        delete changeHandler.argsForCall[0][0].bufferChange
        expect(changeHandler).toHaveBeenCalledWith(start: 5, end: 8, delta: 2)

        expect(tokenizedBuffer.lineForScreenRow(5).indentLevel).toBe 4
        expect(tokenizedBuffer.lineForScreenRow(6).indentLevel).toBe 4
        expect(tokenizedBuffer.lineForScreenRow(11).indentLevel).toBe 2
        expect(tokenizedBuffer.lineForScreenRow(12).indentLevel).toBe 2
        expect(tokenizedBuffer.lineForScreenRow(13).indentLevel).toBe 2

      it "updates the indentLevel of empty lines surrounding a change that removes lines", ->
        # create some new lines
        buffer.insert([7, 0], '\n\n')
        buffer.insert([5, 0], '\n\n')

        tokenizedBuffer.on "changed", changeHandler = jasmine.createSpy('changeHandler')

        buffer.setTextInRange([[7, 0], [8, 65]], '    ok')

        delete changeHandler.argsForCall[0][0].bufferChange
        expect(changeHandler).toHaveBeenCalledWith(start: 5, end: 8, delta: -1)

        expect(tokenizedBuffer.lineForScreenRow(5).indentLevel).toBe 2
        expect(tokenizedBuffer.lineForScreenRow(6).indentLevel).toBe 2
        expect(tokenizedBuffer.lineForScreenRow(7).indentLevel).toBe 2 # new text
        expect(tokenizedBuffer.lineForScreenRow(8).indentLevel).toBe 2
        expect(tokenizedBuffer.lineForScreenRow(9).indentLevel).toBe 2
        expect(tokenizedBuffer.lineForScreenRow(10).indentLevel).toBe 2 # }
