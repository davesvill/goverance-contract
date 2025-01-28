;; Governance contract for decentralized grant distribution
;; Data variables

(define-data-var governor principal tx-sender)    
(define-data-var base-threshold uint u10)          
(define-data-var max-grant-size uint u1000)         

;; Map to track grant history
(define-map grant-history 
  { recipient: principal } 
  { 
    total-amount: uint,
    last-grant-time: uint,
    grant-count: uint
  })

;; Emergency veto status
(define-data-var veto-active bool false)

;; Map to store authorized members
(define-map members principal bool)

;; Number of required approvals for a proposal
(define-data-var required-approvals uint u3)

;; Map to store active proposals
(define-map active-proposals 
  { proposal-id: uint } 
  { proposal-type: (string-ascii 50), parameters: (list 10 int), endorsements: (list 10 principal) })

;; Proposal counter to ensure unique proposal IDs
(define-data-var proposal-counter uint u0)

;; =========================================
;; CORE FUNCTIONS
;; =========================================

;; Function to set a new governor (only callable by the current governor)
(define-public (update-governor (new-governor principal))
  (let ((current-governor (var-get governor)))
    (if (and 
          (is-eq tx-sender current-governor)
          (not (is-eq new-governor current-governor))
          (not (is-eq new-governor 'SP000000000000000000002Q6VF78))) ;; Example: Prevent setting to zero address
      (begin
        (var-set governor new-governor)
        (ok new-governor)
      )
      (err u401)
    )
  )
)

;; Function to update the base threshold amount
(define-public (update-base-threshold (amount uint))
  (if (is-eq tx-sender (var-get governor))
    (if (> amount u0)
      (begin
        (var-set base-threshold amount)
        (ok amount)
      )
      (err u402)
    )
    (err u401)
  )
)

;; Function to update the maximum grant size
(define-public (update-max-grant (amount uint))
  (if (is-eq tx-sender (var-get governor))
    (if (> amount u0)
      (begin
        (var-set max-grant-size amount)
        (ok amount)
      )
      (err u403)
    )
    (err u401)
  )
)

;; Read-only function to check the current governor
(define-read-only (get-governor)
  (ok (var-get governor))
)

;; Read-only function to get the base threshold amount
(define-read-only (get-base-threshold)
  (ok (var-get base-threshold))
)

;; Read-only function to get the current max grant size
(define-read-only (get-max-grant-size)
  (ok (var-get max-grant-size))
)


;; VALIDATION FUNCTIONS
;; Function to validate if a contribution meets the base threshold
(define-public (validate-contribution (amount uint))
  (if (>= amount (var-get base-threshold))
    (ok true)
    (err u404) 
  )
)

;; Function to validate if a grant request is within limits
(define-public (validate-grant-request (amount uint))
  (if (<= amount (var-get max-grant-size))
    (ok true)
    (err u405) 
  )
)


;; MEMBER MANAGEMENT
;; Function to add a new member
(define-public (add-member (new-member principal))
  (begin
    (asserts! (is-eq tx-sender (var-get governor)) (err u401))
    (asserts! (is-none (map-get? members new-member)) (err u403))
    (ok (map-set members new-member true))))

;; Function to remove a member
(define-public (remove-member (member principal))
  (begin
    (asserts! (is-eq tx-sender (var-get governor)) (err u401))
    (asserts! (is-some (map-get? members member)) (err u404))
    (ok (map-delete members member))))


;; PROPOSAL MANAGEMENT
;; Function to submit a new proposal
(define-public (submit-proposal (proposal-type (string-ascii 50)) (parameters (list 10 int)))
  (let 
    (
      (proposal-id (var-get proposal-counter))
      (type-length (len proposal-type))
    )
    (asserts! (is-some (map-get? members tx-sender)) (err u401))
    (asserts! (and (> type-length u0) (<= type-length u50)) (err u402))
    (asserts! (<= (len parameters) u10) (err u403))
    (asserts! (< proposal-id (- (pow u2 u128) u1)) (err u404))  ;; Check for potential overflow
    (map-set active-proposals
      { proposal-id: proposal-id }
      { proposal-type: proposal-type, parameters: parameters, endorsements: (list tx-sender) })
    (var-set proposal-counter (+ proposal-id u1))
    (ok proposal-id)))

;; Function to get proposal details
(define-read-only (get-proposal (proposal-id uint))
  (map-get? active-proposals { proposal-id: proposal-id }))

;; Function to get the current proposal counter
(define-read-only (get-proposal-counter)
  (ok (var-get proposal-counter)))


;; GRANT HISTORY TRACKING
;; Function to record a grant distribution
(define-public (record-grant-distribution (recipient principal) (amount uint))
  (let (
    (current-time (unwrap-panic (get-block-info? time u0)))
    (existing-record (default-to 
      { total-amount: u0, last-grant-time: u0, grant-count: u0 }
      (map-get? grant-history { recipient: recipient })))
  )
    (begin
      ;; Add validation checks
      (asserts! (is-some (map-get? members tx-sender)) (err u401))
      (asserts! (not (is-eq recipient tx-sender)) (err u409))  ;; Prevent self-grants
      (asserts! (not (is-eq recipient (var-get governor))) (err u410))  ;; Prevent grants to governor
      (asserts! (not (is-eq recipient 'SP000000000000000000002Q6VF78)) (err u411))  ;; Prevent grants to zero address
      (asserts! (<= amount (var-get max-grant-size)) (err u405))
      
      ;; Additional checks for recipient
      (asserts! (is-valid-recipient recipient) (err u412))  ;; Check if recipient is valid
      
      (map-set grant-history
        { recipient: recipient }
        { 
          total-amount: (+ (get total-amount existing-record) amount),
          last-grant-time: current-time,
          grant-count: (+ (get grant-count existing-record) u1)
        })
      (ok true))))

;; Function to get grant history for a recipient
(define-read-only (get-recipient-grant-history (recipient principal))
  (map-get? grant-history { recipient: recipient }))

;; Helper function to validate recipient address
(define-private (is-valid-recipient (address principal))
  (and 
    (not (is-eq address (var-get governor)))  ;; Not the governor
    (not (is-some (map-get? members address)))  ;; Not a member
    (not (is-eq address 'SP000000000000000000002Q6VF78))  ;; Not zero address
    (is-standard address)))  ;; Check if it's a standard principal


;; EMERGENCY CONTROLS
;; Function to activate emergency veto (only governor)
(define-public (activate-emergency-veto)
  (begin
    (asserts! (is-eq tx-sender (var-get governor)) (err u401))
    (asserts! (not (var-get veto-active)) (err u406))  ;; Error: Veto already active
    (var-set veto-active true)
    (ok true)))

;; Function to deactivate emergency veto (only governor)
(define-public (deactivate-emergency-veto)
  (begin
    (asserts! (is-eq tx-sender (var-get governor)) (err u401))
    (asserts! (var-get veto-active) (err u407))  ;; Error: Veto not active
    (var-set veto-active false)
    (ok true)))

;; Read-only function to check veto status
(define-read-only (get-veto-status)
  (ok (var-get veto-active)))


;; UTILITY FUNCTIONS
;; Private function to execute a proposal
(define-private (execute-proposal (proposal-id uint))
  (let ((proposal (unwrap! (map-get? active-proposals { proposal-id: proposal-id }) (err u404))))
    (begin
      (asserts! (not (var-get veto-active)) (err u408))
      (map-delete active-proposals { proposal-id: proposal-id })
      (ok true))))

;; Read-only function to check if an address is a member
(define-read-only (is-member (address principal))
  (is-some (map-get? members address)))

;; Read-only function to get the required number of approvals
(define-read-only (get-required-approvals)
  (ok (var-get required-approvals)))

;; Function to update the required number of approvals (only callable by governor)
(define-public (update-required-approvals (new-required uint))
  (begin
    (asserts! (is-eq tx-sender (var-get governor)) (err u401))
    (asserts! (> new-required u0) (err u403))
    (var-set required-approvals new-required)
    (ok true)))