;; Identity Continuity Tracking Contract
;; Maintains personal identity through radical life changes

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-IDENTITY-EXISTS (err u301))
(define-constant ERR-IDENTITY-NOT-FOUND (err u302))
(define-constant ERR-INVALID-TRANSITION (err u303))
(define-constant ERR-INSUFFICIENT-PROOF (err u304))
(define-constant ERR-CONTINUITY-BROKEN (err u305))

;; Data Variables
(define-data-var min-continuity-score uint u70)
(define-data-var transition-cooldown uint u1440) ;; ~1 day in blocks

;; Data Maps
(define-map identities
  { identity-id: (string-ascii 64) }
  {
    owner: principal,
    identity-hash: (string-ascii 64),
    creation-timestamp: uint,
    last-update: uint,
    continuity-score: uint,
    transition-count: uint,
    is-active: bool,
    metadata: (string-ascii 512)
  }
)

(define-map identity-transitions
  { transition-id: (string-ascii 64) }
  {
    from-identity: (string-ascii 64),
    to-identity: (string-ascii 64),
    owner: principal,
    transition-timestamp: uint,
    verification-proof: (string-ascii 256),
    continuity-evidence: (string-ascii 512),
    approved: bool,
    continuity-impact: uint
  }
)

(define-map identity-markers
  { identity-id: (string-ascii 64), marker-type: (string-ascii 32) }
  {
    marker-value: (string-ascii 128),
    timestamp: uint,
    verified: bool,
    importance-weight: uint
  }
)

(define-map continuity-witnesses
  { transition-id: (string-ascii 64), witness: principal }
  {
    attestation: (string-ascii 256),
    confidence-level: uint,
    witness-timestamp: uint,
    verified: bool
  }
)

(define-map identity-history
  { identity-id: (string-ascii 64) }
  {
    previous-identities: (list 10 (string-ascii 64)),
    transition-timeline: (list 10 uint),
    continuity-chain: (list 10 uint),
    total-continuity: uint
  }
)

;; Public Functions

;; Create a new identity record
(define-public (create-identity
  (identity-id (string-ascii 64))
  (identity-hash (string-ascii 64))
  (metadata (string-ascii 512)))
  (let ((existing-identity (map-get? identities { identity-id: identity-id })))
    (asserts! (is-none existing-identity) ERR-IDENTITY-EXISTS)
    (map-set identities
      { identity-id: identity-id }
      {
        owner: tx-sender,
        identity-hash: identity-hash,
        creation-timestamp: block-height,
        last-update: block-height,
        continuity-score: u100,
        transition-count: u0,
        is-active: true,
        metadata: metadata
      })
    (map-set identity-history
      { identity-id: identity-id }
      {
        previous-identities: (list),
        transition-timeline: (list),
        continuity-chain: (list u100),
        total-continuity: u100
      })
    (ok true)))

;; Record an identity transition
(define-public (record-transition
  (transition-id (string-ascii 64))
  (from-identity (string-ascii 64))
  (to-identity (string-ascii 64))
  (verification-proof (string-ascii 256))
  (continuity-evidence (string-ascii 512)))
  (let ((from-id (unwrap! (map-get? identities { identity-id: from-identity }) ERR-IDENTITY-NOT-FOUND))
        (to-id (unwrap! (map-get? identities { identity-id: to-identity }) ERR-IDENTITY-NOT-FOUND)))
    (asserts! (is-eq (get owner from-id) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get owner to-id) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (>= (- block-height (get last-update from-id)) (var-get transition-cooldown)) ERR-INVALID-TRANSITION)

    (let ((continuity-impact (calculate-continuity-impact from-identity to-identity continuity-evidence)))
      (map-set identity-transitions
        { transition-id: transition-id }
        {
          from-identity: from-identity,
          to-identity: to-identity,
          owner: tx-sender,
          transition-timestamp: block-height,
          verification-proof: verification-proof,
          continuity-evidence: continuity-evidence,
          approved: false,
          continuity-impact: continuity-impact
        })
      (ok continuity-impact))))

;; Add identity marker
(define-public (add-identity-marker
  (identity-id (string-ascii 64))
  (marker-type (string-ascii 32))
  (marker-value (string-ascii 128))
  (importance-weight uint))
  (let ((identity (unwrap! (map-get? identities { identity-id: identity-id }) ERR-IDENTITY-NOT-FOUND)))
    (asserts! (is-eq (get owner identity) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (<= importance-weight u100) ERR-NOT-AUTHORIZED)
    (ok (map-set identity-markers
      { identity-id: identity-id, marker-type: marker-type }
      {
        marker-value: marker-value,
        timestamp: block-height,
        verified: false,
        importance-weight: importance-weight
      }))))

;; Add witness attestation
(define-public (add-witness-attestation
  (transition-id (string-ascii 64))
  (attestation (string-ascii 256))
  (confidence-level uint))
  (let ((transition (unwrap! (map-get? identity-transitions { transition-id: transition-id }) ERR-IDENTITY-NOT-FOUND)))
    (asserts! (<= confidence-level u100) ERR-NOT-AUTHORIZED)
    (ok (map-set continuity-witnesses
      { transition-id: transition-id, witness: tx-sender }
      {
        attestation: attestation,
        confidence-level: confidence-level,
        witness-timestamp: block-height,
        verified: false
      }))))

;; Approve identity transition
(define-public (approve-transition (transition-id (string-ascii 64)))
  (let ((transition (unwrap! (map-get? identity-transitions { transition-id: transition-id }) ERR-IDENTITY-NOT-FOUND)))
    (asserts! (is-eq (get owner transition) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (not (get approved transition)) ERR-NOT-AUTHORIZED)

    (let ((continuity-score (calculate-transition-continuity transition-id)))
      (asserts! (>= continuity-score (var-get min-continuity-score)) ERR-CONTINUITY-BROKEN)

      ;; Update transition
      (map-set identity-transitions
        { transition-id: transition-id }
        (merge transition { approved: true }))

      ;; Update identities
      (try! (update-identity-continuity (get from-identity transition) (get to-identity transition) continuity-score))
      (ok continuity-score))))

;; Update identity information
(define-public (update-identity
  (identity-id (string-ascii 64))
  (identity-hash (string-ascii 64))
  (metadata (string-ascii 512)))
  (let ((identity (unwrap! (map-get? identities { identity-id: identity-id }) ERR-IDENTITY-NOT-FOUND)))
    (asserts! (is-eq (get owner identity) tx-sender) ERR-NOT-AUTHORIZED)
    (ok (map-set identities
      { identity-id: identity-id }
      (merge identity {
        identity-hash: identity-hash,
        last-update: block-height,
        metadata: metadata
      })))))

;; Private Functions

(define-private (calculate-continuity-impact
  (from-identity (string-ascii 64))
  (to-identity (string-ascii 64))
  (evidence (string-ascii 512)))
  (let ((base-impact u80))
    (+ base-impact (/ (len evidence) u10))))

(define-private (calculate-transition-continuity (transition-id (string-ascii 64)))
  (let ((transition (unwrap-panic (map-get? identity-transitions { transition-id: transition-id }))))
    (get continuity-impact transition)))

(define-private (update-identity-continuity
  (from-identity (string-ascii 64))
  (to-identity (string-ascii 64))
  (continuity-score uint))
  (let ((from-id (unwrap! (map-get? identities { identity-id: from-identity }) ERR-IDENTITY-NOT-FOUND))
        (to-id (unwrap! (map-get? identities { identity-id: to-identity }) ERR-IDENTITY-NOT-FOUND)))

    ;; Update from-identity
    (map-set identities
      { identity-id: from-identity }
      (merge from-id {
        is-active: false,
        continuity-score: continuity-score,
        transition-count: (+ (get transition-count from-id) u1)
      }))

    ;; Update to-identity
    (map-set identities
      { identity-id: to-identity }
      (merge to-id {
        continuity-score: continuity-score,
        transition-count: (+ (get transition-count to-id) u1),
        last-update: block-height
      }))

    ;; Update history
    (let ((history (default-to
                     { previous-identities: (list), transition-timeline: (list), continuity-chain: (list), total-continuity: u0 }
                     (map-get? identity-history { identity-id: to-identity }))))
      (map-set identity-history
        { identity-id: to-identity }
        {
          previous-identities: (unwrap! (as-max-len? (append (get previous-identities history) from-identity) u10) ERR-NOT-AUTHORIZED),
          transition-timeline: (unwrap! (as-max-len? (append (get transition-timeline history) block-height) u10) ERR-NOT-AUTHORIZED),
          continuity-chain: (unwrap! (as-max-len? (append (get continuity-chain history) continuity-score) u10) ERR-NOT-AUTHORIZED),
          total-continuity: (/ (+ (get total-continuity history) continuity-score) u2)
        }))
    (ok true)))

;; Read-only Functions

(define-read-only (get-identity (identity-id (string-ascii 64)))
  (map-get? identities { identity-id: identity-id }))

(define-read-only (get-transition (transition-id (string-ascii 64)))
  (map-get? identity-transitions { transition-id: transition-id }))

(define-read-only (get-identity-marker (identity-id (string-ascii 64)) (marker-type (string-ascii 32)))
  (map-get? identity-markers { identity-id: identity-id, marker-type: marker-type }))

(define-read-only (get-witness-attestation (transition-id (string-ascii 64)) (witness principal))
  (map-get? continuity-witnesses { transition-id: transition-id, witness: witness }))

(define-read-only (get-identity-history (identity-id (string-ascii 64)))
  (map-get? identity-history { identity-id: identity-id }))

(define-read-only (get-continuity-score (identity-id (string-ascii 64)))
  (match (map-get? identities { identity-id: identity-id })
    identity (get continuity-score identity)
    u0))
