;; Memory Authenticity Verification Contract
;; Distinguishes between real and artificially implanted memories

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-MEMORY-EXISTS (err u201))
(define-constant ERR-MEMORY-NOT-FOUND (err u202))
(define-constant ERR-INVALID-SIGNATURE (err u203))
(define-constant ERR-INVALID-TIMESTAMP (err u204))
(define-constant ERR-INSUFFICIENT-VALIDATORS (err u205))

;; Data Variables
(define-data-var min-validators uint u3)
(define-data-var validation-threshold uint u2)

;; Data Maps
(define-map memories
  { memory-id: (string-ascii 64) }
  {
    owner: principal,
    memory-hash: (string-ascii 64),
    creation-timestamp: uint,
    source-signature: (string-ascii 128),
    authenticity-score: uint,
    validation-count: uint,
    is-authentic: bool,
    metadata: (string-ascii 256)
  }
)

(define-map memory-validators
  { memory-id: (string-ascii 64), validator: principal }
  {
    validation-timestamp: uint,
    authenticity-vote: bool,
    confidence-score: uint,
    validation-signature: (string-ascii 128)
  }
)

(define-map validator-registry
  { validator: principal }
  {
    reputation-score: uint,
    total-validations: uint,
    correct-validations: uint,
    registration-timestamp: uint,
    is-active: bool
  }
)

(define-map memory-chains
  { memory-id: (string-ascii 64) }
  {
    parent-memory: (optional (string-ascii 64)),
    child-memories: (list 20 (string-ascii 64)),
    chain-depth: uint,
    chain-integrity: bool
  }
)

;; Public Functions

;; Register a new memory
(define-public (register-memory
  (memory-id (string-ascii 64))
  (memory-hash (string-ascii 64))
  (source-signature (string-ascii 128))
  (metadata (string-ascii 256)))
  (let ((existing-memory (map-get? memories { memory-id: memory-id })))
    (asserts! (is-none existing-memory) ERR-MEMORY-EXISTS)
    (asserts! (> block-height u0) ERR-INVALID-TIMESTAMP)
    (ok (map-set memories
      { memory-id: memory-id }
      {
        owner: tx-sender,
        memory-hash: memory-hash,
        creation-timestamp: block-height,
        source-signature: source-signature,
        authenticity-score: u0,
        validation-count: u0,
        is-authentic: false,
        metadata: metadata
      }))))

;; Register as a validator
(define-public (register-validator)
  (let ((existing-validator (map-get? validator-registry { validator: tx-sender })))
    (asserts! (is-none existing-validator) ERR-NOT-AUTHORIZED)
    (ok (map-set validator-registry
      { validator: tx-sender }
      {
        reputation-score: u100,
        total-validations: u0,
        correct-validations: u0,
        registration-timestamp: block-height,
        is-active: true
      }))))

;; Validate memory authenticity
(define-public (validate-memory
  (memory-id (string-ascii 64))
  (authenticity-vote bool)
  (confidence-score uint)
  (validation-signature (string-ascii 128)))
  (let ((memory (unwrap! (map-get? memories { memory-id: memory-id }) ERR-MEMORY-NOT-FOUND))
        (validator (unwrap! (map-get? validator-registry { validator: tx-sender }) ERR-NOT-AUTHORIZED)))
    (asserts! (get is-active validator) ERR-NOT-AUTHORIZED)
    (asserts! (<= confidence-score u100) ERR-NOT-AUTHORIZED)
    (asserts! (is-none (map-get? memory-validators { memory-id: memory-id, validator: tx-sender })) ERR-NOT-AUTHORIZED)

    ;; Record validation
    (map-set memory-validators
      { memory-id: memory-id, validator: tx-sender }
      {
        validation-timestamp: block-height,
        authenticity-vote: authenticity-vote,
        confidence-score: confidence-score,
        validation-signature: validation-signature
      })

    ;; Update validator stats
    (map-set validator-registry
      { validator: tx-sender }
      (merge validator {
        total-validations: (+ (get total-validations validator) u1)
      }))

    ;; Update memory validation count
    (let ((new-validation-count (+ (get validation-count memory) u1)))
      (map-set memories
        { memory-id: memory-id }
        (merge memory {
          validation-count: new-validation-count
        }))

      ;; Check if enough validations to determine authenticity
      (if (>= new-validation-count (var-get min-validators))
        (try! (finalize-authenticity memory-id))
        (ok true)))))

;; Finalize memory authenticity determination
(define-private (finalize-authenticity (memory-id (string-ascii 64)))
  (let ((memory (unwrap! (map-get? memories { memory-id: memory-id }) ERR-MEMORY-NOT-FOUND)))
    (let ((authenticity-result (calculate-authenticity-score memory-id)))
      (map-set memories
        { memory-id: memory-id }
        (merge memory {
          authenticity-score: (get score authenticity-result),
          is-authentic: (get is-authentic authenticity-result)
        }))
      (ok true))))

;; Create memory chain link
(define-public (link-memory-chain
  (parent-memory-id (string-ascii 64))
  (child-memory-id (string-ascii 64)))
  (let ((parent-memory (unwrap! (map-get? memories { memory-id: parent-memory-id }) ERR-MEMORY-NOT-FOUND))
        (child-memory (unwrap! (map-get? memories { memory-id: child-memory-id }) ERR-MEMORY-NOT-FOUND)))
    (asserts! (is-eq (get owner parent-memory) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get owner child-memory) tx-sender) ERR-NOT-AUTHORIZED)

    (let ((parent-chain (default-to
                          { parent-memory: none, child-memories: (list), chain-depth: u0, chain-integrity: true }
                          (map-get? memory-chains { memory-id: parent-memory-id }))))
      (map-set memory-chains
        { memory-id: parent-memory-id }
        (merge parent-chain {
          child-memories: (unwrap! (as-max-len? (append (get child-memories parent-chain) child-memory-id) u20) ERR-NOT-AUTHORIZED)
        }))

      (map-set memory-chains
        { memory-id: child-memory-id }
        {
          parent-memory: (some parent-memory-id),
          child-memories: (list),
          chain-depth: (+ (get chain-depth parent-chain) u1),
          chain-integrity: true
        })
      (ok true))))

;; Private Functions

(define-private (calculate-authenticity-score (memory-id (string-ascii 64)))
  (let ((validations (get-memory-validations memory-id)))
    (let ((total-score (fold + (map get-validation-score validations) u0))
          (total-validations (len validations)))
      (if (> total-validations u0)
        {
          score: (/ total-score total-validations),
          is-authentic: (>= (/ total-score total-validations) u60)
        }
        {
          score: u0,
          is-authentic: false
        }))))

(define-private (get-validation-score (validation { validation-timestamp: uint, authenticity-vote: bool, confidence-score: uint, validation-signature: (string-ascii 128) }))
  (if (get authenticity-vote validation)
    (get confidence-score validation)
    (- u100 (get confidence-score validation))))

(define-private (get-memory-validations (memory-id (string-ascii 64)))
  (list))

;; Read-only Functions

(define-read-only (get-memory (memory-id (string-ascii 64)))
  (map-get? memories { memory-id: memory-id }))

(define-read-only (get-memory-validation (memory-id (string-ascii 64)) (validator principal))
  (map-get? memory-validators { memory-id: memory-id, validator: validator }))

(define-read-only (get-validator-info (validator principal))
  (map-get? validator-registry { validator: validator }))

(define-read-only (get-memory-chain (memory-id (string-ascii 64)))
  (map-get? memory-chains { memory-id: memory-id }))

(define-read-only (is-memory-authentic (memory-id (string-ascii 64)))
  (match (map-get? memories { memory-id: memory-id })
    memory (get is-authentic memory)
    false))
