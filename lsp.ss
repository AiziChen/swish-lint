;;; Copyright 2020 Beckman Coulter, Inc.
;;;
;;; Permission is hereby granted, free of charge, to any person
;;; obtaining a copy of this software and associated documentation
;;; files (the "Software"), to deal in the Software without
;;; restriction, including without limitation the rights to use, copy,
;;; modify, merge, publish, distribute, sublicense, and/or sell copies
;;; of the Software, and to permit persons to whom the Software is
;;; furnished to do so, subject to the following conditions:
;;;
;;; The above copyright notice and this permission notice shall be
;;; included in all copies or substantial portions of the Software.
;;;
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;;; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
;;; HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
;;; WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
;;; DEALINGS IN THE SOFTWARE.

(library (lsp)
  (export
   lsp:start-server
   )
  (import
   (checkers)
   (chezscheme)
   (indent)
   (json)
   (keywords)
   (progress)
   (read)
   (swish imports)
   (tower-client)
   (trace)
   )

  (define (lsp:start-reader ip proc)
    `#(ok
       ,(spawn&link
         (lambda ()
           (let lp ([header '()])
             (let ([line (get-line ip)])
               (if (string=? line "")
                   (lp header)
                   (match (pregexp-match (re "(\\S+): (\\S+)") line)
                     [(,_ ,key ,val) (lp (cons (cons key val) header))]
                     [#f
                      (proc (json:read ip))
                      (lp '())]))))))))

  (define (lsp:start-writer op)
    `#(ok
       ,(spawn&link
         (lambda ()
           (register 'lsp-writer self)
           (let lp ([timeout 'infinity])
             (receive
              (after timeout
                (flush-output-port op)
                (lp 'infinity))
              [#(send-msg ,msg)
               (let* ([bv (json:object->bytevector msg)]
                      [str (utf8->string bv)])
                 (fprintf op "Content-Length: ~a\r\n\r\n" (bytevector-length bv))
                 (display-string str op)
                 (lp 1))]))))))

  (define (lsp:send msg)
    (unless (json:object? msg)
      (bad-arg 'lsp:send msg))
    (send 'lsp-writer `#(send-msg ,msg)))

  (define (lsp:log type msg)
    (unless (string? msg)
      (bad-arg 'lsp:log msg))
    (rpc:fire-event "window/logMessage"
      (json:make-object
       [type
        (match type
          [error 1]
          [warning 2]
          [info 3]
          [log 4])]
       [message msg])))

  (define (rpc:respond id result)
    (let ([res (json:make-object [jsonrpc "2.0"] [id id])])
      (when result
        (json:extend-object res [result result]))
      (lsp:send res)))

  (define (rpc:request id method params)
    (lsp:send
     (trace-msg
      (json:make-object
       [jsonrpc "2.0"]
       [id id]
       [method method]
       [params params]))))

  (define (rpc:fire-event method params)
    (lsp:send
     (json:make-object
      [jsonrpc "2.0"]
      [method method]
      [params params])))

  (define (rpc:respond-error id code reason)
    (lsp:send
     (json:make-object
      [jsonrpc "2.0"]
      [id id]
      [error
       (json:make-object
        [code code]
        [message (exit-reason->english reason)]
        [data (format "~s" reason)])])))

  (define (make-pos line char)
    (json:make-object [line line] [character char]))

  (define (make-range start end)
    (json:make-object [start start] [end end]))

  (define (make-location uri range)
    (json:make-object [uri uri] [range range]))

  (define (make-text-edit range text)
    (json:make-object [range range] [newText text]))

  (define (make-progress token title render-msg)
    (match (progress:start title render-msg
             (lambda (msg)
               (rpc:fire-event "$/progress"
                 (json:make-object
                  [token token]
                  [value msg])))
             trace-expr)
      [#(ok ,pid) pid]
      [#(error ,reason)
       (trace-expr `(make-progress => ,(exit-reason->english reason)))
       #f]))

  (define (get-symbol-name x)
    (define (clean? s)
      (let ([len (string-length s)])
        (let lp ([i 0])
          (cond
           [(fx= i len) #t]
           [(char-whitespace? (string-ref s i)) #f]
           [else (lp (fx1+ i))]))))
    (cond
     [(gensym? x) (parameterize ([print-gensym #t]) (format "~s" x))]
     [(symbol? x)
      (let ([s (symbol->string x)])
        (if (clean? s)
            s
            (format "|~a|" s)))]
     [else x]))

  (define (doc:start&link uri init-text progress)
    (define-state-tuple <document> text worker-pid)
    (define (init text)
      `#(ok ,(<document> make
               [text text]
               [worker-pid
                (if text
                    (start-check text #t)
                    (start-update-refs progress))])))
    (define (terminate reason state) 'ok)
    (define (handle-call msg from state)
      (match msg
        [get-text
         `#(reply ,($state text) ,state)]
        [#(get-value-near ,line ,char)
         (let ([table (make-code-lookup-table ($state text))])
           (match (try
                   (let-values ([(type value bfp efp)
                                 (read-token-near ($state text) table line char)])
                     (and (eq? type 'atomic)
                          (match value
                            [,_ (guard (symbol? value))
                             (get-symbol-name value)]
                            [($primitive ,value)
                             (get-symbol-name value)]
                            [($primitive ,_ ,value)
                             (get-symbol-name value)]
                            [,_ #f]))))
             [`(catch ,reason)
              (trace-expr
               `(get-value-near ,line ,char => ,(exit-reason->english reason)))
              `#(reply #f ,state)]
             ["" `#(reply #f ,state)]
             [,result
              `#(reply ,result ,state)]))]))
    (define (handle-cast msg state)
      (match msg
        [#(updated ,text ,skip-delay?)
         (let ([pid ($state worker-pid)])
           (when pid (kill pid 'cancelled)))
         `#(no-reply
            ,($state copy
               [text text]
               [worker-pid (start-check text skip-delay?)]))]))
    (define (handle-info msg state) (match msg))

    (define (publish-diagnostics)
      (rpc:fire-event "textDocument/publishDiagnostics"
        (json:make-object
         [uri uri]
         [diagnostics (current-diagnostics)])))

    (define (start-check text skip-delay?)
      (spawn
       (lambda ()
         (unless skip-delay?
           (receive (after 1000 'ok)))
         (check uri text)
         (publish-diagnostics)
         (unless skip-delay?
           (receive (after 30000 'ok)))
         (check-line-whitespace text #t report)
         (publish-diagnostics))))

    (define (start-update-refs progress)
      (define pid
        (spawn
         (lambda ()
           (with-gatekeeper-mutex $update-refs 'infinity
             (let* ([filename (uri->abs-path uri)]
                    [text (utf8->string (read-file filename))]
                    [annotated-code (read-code text)]
                    [source-table (make-code-lookup-table text)])
               (do-update-refs uri text annotated-code source-table))))))
      (when progress
        (progress:inc-total progress)
        (spawn
         (lambda ()
           (monitor pid)
           (receive
            [`(DOWN ,_ ,_ ,_)
             (progress:inc-done progress)]))))
      pid)

    (gen-server:start&link #f init-text))

  (define (doc:get-text who)
    (gen-server:call who 'get-text))

  (define (doc:get-value-near who line char)
    (gen-server:call who `#(get-value-near ,line ,char)))

  (define current-diagnostics (make-process-parameter '()))

  (define (add-diagnostic d)
    (current-diagnostics (cons d (current-diagnostics))))

  (define current-source-table (make-process-parameter #f))

  (define (type->severity type)
    (match type
      [error 1]
      [warning 2]
      [info 3]
      [hint 4]))

  (define (report x type fmt . args)
    (add-diagnostic
     (json:make-object
      [severity (type->severity type)]
      [message (apply format fmt args)]
      [range
       (match x
         [,line (guard (fixnum? line))
          (let ([line (- line 1)])      ; LSP is 0-based
            (make-range (make-pos line 0) (make-pos (+ line 1) 0)))]
         [#(range ,start-line ,start-column ,end-line ,end-column)
          (guard (and (fixnum? start-line) (fixnum? start-column)
                      (fixnum? end-line) (fixnum? end-column)))
          (let ([start-line (- start-line 1)] ; LSP is 0-based
                [end-line (- end-line 1)])
            (make-range (make-pos start-line start-column)
              (make-pos end-line end-column)))]
         [`(annotation [source ,src])
          (let* ([bfp (source-object-bfp src)]
                 [efp (source-object-efp src)]
                 [table (current-source-table)])
            (let-values ([(bl bc) (fp->line/char table bfp)]
                         [(el ec) (fp->line/char table efp)])
              (let ([bl (- bl 1)]       ; LSP is 0-based
                    [el (- el 1)]
                    [bc (- bc 1)]
                    [ec (- ec 1)])
                (make-range (make-pos bl bc) (make-pos el ec)))))])])))

  (define (check uri text)
    (match (try (read-code text))
      [`(catch ,reason)
       (let ([table (make-code-lookup-table text)])
         (spawn-update-refs uri #f table text)
         (let-values ([(line msg) (reason->line/msg reason table)])
           (report line 'error msg)))]
      [,annotated-code
       (let ([source-table (make-code-lookup-table text)])
         (spawn-update-refs uri annotated-code source-table text)
         (current-source-table source-table)
         (check-import/export annotated-code report)
         (run-optional-checkers annotated-code text report))]))

  (define (do-update-refs uri text annotated-code source-table)
    (let ([filename (uri->abs-path uri)]
          [refs (make-hashtable string-hash string=?)])
      (define (key name line char)
        (format "~a:~a:~a" name line char))
      (define (try-walk who walk code get-bfp meta)
        (match
         (try
          (walk code source-table
            (lambda (table name source)
              (let-values ([(line char) (fp->line/char table (get-bfp source))])
                (let ([new (json:make-object
                            [name (get-symbol-name name)]
                            [line line]
                            [char char]
                            [meta meta])])
                  (hashtable-update! refs (key name line char)
                    (lambda (old)
                      (if old
                          (json:merge old new)
                          new))
                    #f))))))
         [`(catch ,reason)
          (trace-expr `(,who => ,(exit-reason->english reason)))
          #f]
         [,_ #t]))
      (define (defns-anno)
        (and annotated-code
             (try-walk 'walk-defns walk-defns annotated-code source-object-bfp
               (json:make-object
                [definition 1]
                [anno-pass 1]))))
      (define (defns-re)
        (try-walk 'walk-defns-re walk-defns-re text car
          (json:make-object
           [definition 1]
           [regexp-pass 1])))
      (define (refs-anno)
        (and annotated-code
             (try-walk 'walk-refs walk-refs annotated-code source-object-bfp
               (json:make-object
                [anno-pass 1]))))
      (define (refs-re)
        (try-walk 'walk-refs-re walk-refs-re text car
          (json:make-object
           [regexp-pass 1])))
      (or (defns-anno) (defns-re))
      (or (refs-anno) (refs-re))
      (tower-client:update-references filename
        (vector->list (hashtable-values refs)))))

  (define (spawn-update-refs uri annotated-code source-table text)
    (spawn&link
     (lambda ()
       (catch (do-update-refs uri text annotated-code source-table)))))

  (define (get-completions doc uri line char)
    (let ([line (+ line 1)]       ; LSP is 0-based
          #;[char (+ char 1)])    ; ... but we want the preceding char
      (cond
       [(doc:get-value-near doc line char) =>
        (lambda (prefix)
          (tower-client:get-completions (uri->abs-path uri) line char prefix))]
       [else '()])))

  (define (get-definitions doc uri line char)
    (let ([line (+ line 1)]             ; LSP is 0-based
          [char (+ char 1)])
      (cond
       [(doc:get-value-near doc line char) =>
        (lambda (name)
          (map
           (lambda (defn)
             (let ([uri (abs-path->uri (json:ref defn 'filename #f))]
                   [line (- (json:ref defn 'line #f) 1)] ; LSP is 0-based
                   [char (- (json:ref defn 'char #f) 1)])
               (make-location uri
                 (make-range
                  (make-pos line char)
                  (make-pos line (+ char (string-length name)))))))
           (tower-client:get-definitions (uri->abs-path uri) name)))]
       [else '()])))

  (define (get-references doc uri line char)
    (let ([line (+ line 1)]             ; LSP is 0-based
          [char (+ char 1)])
      (cond
       [(doc:get-value-near doc line char) =>
        (lambda (name)
          (map
           (lambda (ref)
             (let ([uri (abs-path->uri (json:ref ref 'filename #f))]
                   [line (- (json:ref ref 'line #f) 1)] ; LSP is 0-based
                   [char (- (json:ref ref 'char #f) 1)])
               (make-location uri
                 (make-range
                  (make-pos line char)
                  (make-pos line (+ char (string-length name)))))))
           (tower-client:get-references (uri->abs-path uri) name)))]
       [else '()])))

  (define (highlight-references doc uri line char)
    (let ([line (+ line 1)]             ; LSP is 0-based
          [char (+ char 1)])
      (cond
       [(doc:get-value-near doc line char) =>
        (lambda (name)
          (map
           (lambda (ref)
             (let ([line (- (json:ref ref 'line #f) 1)] ; LSP is 0-based
                   [char (- (json:ref ref 'char #f) 1)])
               (json:make-object
                [kind 1]                ; Text
                [range
                 (make-range
                  (make-pos line char)
                  (make-pos line (+ char (string-length name))))])))
           (tower-client:get-local-references (uri->abs-path uri) name)))]
       [else '()])))

  (define (indent-range doc range options)
    (let* ([start (or (and range (json:ref range '(start line) #f)) 0)]
           [end (or (and range (json:ref range '(end line) #f))
                    (most-positive-fixnum))]
           [end-char (or (and range (json:ref range '(end character) #f))
                         0)]
           [end (if (zero? end-char)
                    (- end 1)
                    end)])
      (trace-time 'indent
        (reverse
         (fold-indent (doc:get-text doc) '()
           (lambda (line old new acc)
             (let ([line (- line 1)])   ; LSP is 0-based
               (if (and (<= start line end)
                        (not (string=? old new)))
                   (cons
                    (make-text-edit
                     (make-range
                      (make-pos line 0)
                      (make-pos line (max (string-length old)
                                          (string-length new))))
                     new)
                    acc)
                   acc))))))))

  (define (find-files path . extensions)
    (define (combine path fn) (if (equal? "." path) fn (path-combine path fn)))
    (let search ([path path] [hits '()])
      (match (try (list-directory path))
        [`(catch ,_) hits]
        [,found
         (fold-left
          (lambda (hits entry)
            (match entry
              [(,fn . ,@DIRENT_DIR)
               (let ([full (combine path fn)])
                 (cond
                  [(string=? fn ".git") hits] ; skip the actual repo tree
                  [(file-exists? (path-combine full ".git")) hits] ; skip repos
                  [else (search full hits)]))]
              [(,fn . ,@DIRENT_FILE)
               (if (member (path-extension fn) extensions)
                   (cons (combine path fn) hits)
                   hits)]
              [,_ hits])) ;; not following symlinks
          hits
          found)])))

  (define (lsp-server:start&link)
    (define-state-tuple <lsp-server>
      root-uri
      root-dir
      req->pid
      pid->req
      uri->doc
      client-cap
      requests
      )
    (define (init)
      `#(ok ,(<lsp-server> make
               [root-uri #f]
               [root-dir #f]
               [req->pid (ht:make equal-hash equal?
                           (lambda (x) (or (fixnum? x) (string? x))))]
               [pid->req (ht:make process-id eq? process?)]
               [uri->doc (ht:make string-hash string=? string?)]
               [client-cap #f]
               [requests (ht:make string-hash string=? string?)]
               )))
    (define (terminate reason state) 'ok)
    (define (handle-call msg from state)
      (match msg
        [#(incoming-message ,msg)
         (let ([id (json:ref msg 'id #f)])
           (cond
            [(not id)
             (let ([method (json:get msg 'method)]
                   [params (json:get msg 'params)])
               `#(reply ok ,(handle-notify method params state)))]
            [(and (string? id) (ht:ref ($state requests) id #f))
             (trace-expr 'received-reply)
             (trace-msg msg)
             `#(reply ok ,($state copy* [requests (ht:delete requests id)]))]
            [else
             (let ([method (json:get msg 'method)]
                   [params (json:get msg 'params)])
               `#(reply ok ,(do-handle-request id method params state)))]))]))
    (define (handle-cast msg state) (match msg))
    (define (handle-info msg state)
      (match msg
        [#(request-finished ,pid ,id ,result)
         (rpc:respond id result)
         `#(no-reply ,(delete-req id pid state))]
        [`(DOWN ,_ ,pid ,reason)
         (cond
          [(ht:ref ($state pid->req) pid #f) =>
           (lambda (id)
             (rpc:respond-error id -32000 reason)
             `#(no-reply ,(delete-req id pid state)))]
          [else
           `#(no-reply ,state)])]))

    (define (delete-req id pid state)
      ($state copy*
        [req->pid (ht:delete req->pid id)]
        [pid->req (ht:delete pid->req pid)]))

    (define (updated uri text skip-delay? progress state)
      (cond
       [(ht:ref ($state uri->doc) uri #f) =>
        (lambda (doc)
          (gen-server:cast doc `#(updated ,text ,skip-delay?))
          state)]
       [else
        (match-let*
         ([#(ok ,pid)
           (watcher:start-child 'main-sup (gensym "document") 1000
             (lambda () (doc:start&link uri text progress)))])
         ($state copy* [uri->doc (ht:set uri->doc uri pid)]))]))

    (define (do-handle-request id method params state)
      (match (try (handle-request id method params state))
        [`(catch ,reason)
         (rpc:respond-error id -32000 reason)
         state]
        [#(ok ,result ,state)
         (rpc:respond id result)
         state]
        [#(ignore ,state)
         state]
        [#(spawn ,thunk ,state)
         (let* ([me self]
                [pid (spawn
                      (lambda ()
                        (send me `#(request-finished ,self ,id ,(thunk)))))])
           (monitor pid)
           ($state copy*
             [req->pid (ht:set req->pid id pid)]
             [pid->req (ht:set pid->req pid id)]))]))

    (define (handle-request id method params state)
      (match method
        ["initialize"
         ;;(trace-msg (json:make-object [method method] [params params]))
         (let* ([root-uri (json:get params '(rootUri))]
                [root-dir (uri->abs-path root-uri)]
                [client-cap (json:get params '(capabilities))])
           (tower-client:reset-directory root-dir)
           `#(ok
              ,(json:make-object
                [capabilities
                 (json:make-object
                  [textDocumentSync
                   (json:make-object
                    [openClose #t]
                    [change 1]          ; Full
                    [willSave #f]
                    [willSaveWaitUntil #f]
                    [save (json:make-object [includeText #t])])]
                  [hoverProvider #f]
                  [completionProvider #t]
                  [definitionProvider #t]
                  [referencesProvider #t]
                  [documentHighlightProvider #t]
                  [documentFormattingProvider #t]
                  [documentRangeFormattingProvider #t]
                  )])
              ,($state copy
                 [root-uri root-uri]
                 [root-dir root-dir]
                 [client-cap client-cap])))]
        ["textDocument/hover"
         `#(ok #f ,state)]
        ["textDocument/completion"
         (let ([uri (json:get params '(textDocument uri))]
               [line (json:get params '(position line))]
               [char (json:get params '(position character))])
           (cond
            [(ht:ref ($state uri->doc) uri #f) =>
             (lambda (doc)
               `#(spawn ,(lambda () (get-completions doc uri line char)) ,state))]
            [else `#(ok () ,state)]))]
        ["textDocument/definition"
         (let ([uri (json:get params '(textDocument uri))]
               [line (json:get params '(position line))]
               [char (json:get params '(position character))])
           (cond
            [(ht:ref ($state uri->doc) uri #f) =>
             (lambda (doc)
               `#(spawn ,(lambda () (get-definitions doc uri line char)) ,state))]
            [else `#(ok () ,state)]))]
        ["textDocument/references"
         (let ([uri (json:get params '(textDocument uri))]
               [line (json:get params '(position line))]
               [char (json:get params '(position character))])
           (cond
            [(ht:ref ($state uri->doc) uri #f) =>
             (lambda (doc)
               `#(spawn ,(lambda () (get-references doc uri line char)) ,state))]
            [else `#(ok () ,state)]))]
        ["textDocument/documentHighlight"
         (let ([uri (json:get params '(textDocument uri))]
               [line (json:get params '(position line))]
               [char (json:get params '(position character))])
           (cond
            [(ht:ref ($state uri->doc) uri #f) =>
             (lambda (doc)
               `#(spawn ,(lambda () (highlight-references doc uri line char)) ,state))]
            [else `#(ok () ,state)]))]
        ["textDocument/formatting"
         (let ([uri (json:get params '(textDocument uri))]
               [options (json:get params 'options)])
           (cond
            [(ht:ref ($state uri->doc) uri #f) =>
             (lambda (doc)
               `#(ok ,(indent-range doc #f options) ,state))]
            [else `#(ok () ,state)]))]
        ["textDocument/rangeFormatting"
         (let ([uri (json:get params '(textDocument uri))]
               [range (json:get params 'range)]
               [options (json:get params 'options)])
           (cond
            [(ht:ref ($state uri->doc) uri #f) =>
             (lambda (doc)
               `#(ok ,(indent-range doc range options) ,state))]
            [else `#(ok () ,state)]))]
        ["shutdown"
         `#(ok #\nul ,state)]
        [,_
         (fprintf (console-error-port) "*** Unhandled message ***\n")
         (trace-msg (json:make-object [id id] [method method] [params params]))
         `#(ignore ,state)]))

    (define (handle-notify method params state)
      (match method
        ["$/cancelRequest"
         (let ([id (json:get params '(id))])
           (cond
            [(ht:ref ($state req->pid) id #f) =>
             (lambda (pid)
               (kill pid 'cancelled)
               (rpc:respond-error id -32800 "Cancelled")
               (delete-req id pid state))]
            [else state]))]
        ["initialized"
         (let ([progress (make-progress "enumerate-directories"
                           "Analyze files"
                           (lambda (done total)
                             (format "~a/~a files" done total)))])
           (trace-time 'enumerate-directories
             (fold-left
              (lambda (state fn)
                (updated (abs-path->uri fn) #f #t progress state))
              state
              (find-files ($state root-dir) "ss" "ms"))))]
        ["textDocument/didOpen"
         (let ([doc (json:get params '(textDocument))])
           (updated (json:get doc '(uri)) (json:get doc '(text)) #t #f state))]
        ["textDocument/didChange"
         (updated
          (json:get params '(textDocument uri))
          (json:get (car (last-pair (json:get params '(contentChanges)))) '(text))
          #f
          #f
          state)]
        ["textDocument/didSave"
         (updated
          (json:get params '(textDocument uri))
          (json:get params '(text))
          #t
          #f
          state)]
        ["textDocument/didClose" state]
        ["exit" (exit 0)]
        [,_
         (fprintf (console-error-port) "*** Unhandled message ***\n")
         (trace-msg (json:make-object [method method] [params params]))
         state]))

    (gen-server:start&link 'lsp-server))

  (define (lsp-server:incoming-message msg)
    (gen-server:call 'lsp-server `#(incoming-message ,msg)))

  (define (lsp:start-server)
    (hook-console-input)
    (trace-init)
    ;; Manually build the whole app-sup-spec. No real need to manage a
    ;; log database or statistics gathering for the LSP client.
    (app-sup-spec
     `(#(event-mgr ,event-mgr:start&link permanent 1000 worker)
       #(gatekeeper ,gatekeeper:start&link permanent 1000 worker)
       #(tower-client ,tower-client:start&link permanent 1000 worker)
       #(tower-log
         ,(lambda ()
            (match (event-mgr:set-log-handler
                    (lambda (e) (tower-client:log (coerce e)))
                    (whereis 'tower-client))
              [ok
               (event-mgr:flush-buffer)
               'ignore]
              [,error error]))
         temporary 1000 worker)
       #(lsp-server ,lsp-server:start&link permanent 1000 worker)
       #(lsp:writer
         ,(lambda () (lsp:start-writer (console-output-port)))
         permanent 1000 worker)
       #(lsp:reader
         ,(lambda () (lsp:start-reader (console-input-port)
                       lsp-server:incoming-message))
         permanent 1000 worker)
       #(event-mgr-sentry               ; Should be last
         ,(lambda ()
            `#(ok ,(spawn&link
                    (lambda ()
                      ;; Unregister event-mgr so that event-mgr:notify
                      ;; no longer sends events to tower-log but to
                      ;; the console. LSP is particularly hard to
                      ;; debug during a crash, so more messages to the
                      ;; console, the better.
                      (process-trap-exit #t)
                      (receive
                       [`(EXIT ,_ ,_) (event-mgr:unregister)])))))
         permanent 1000 worker)
       ))
    (trace-versions)
    (app:start)
    (receive))
  )
