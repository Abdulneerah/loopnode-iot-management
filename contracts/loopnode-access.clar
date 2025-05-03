;; =====================================
;; LoopNode Access Management Contract
;; =====================================
;; This contract manages access requests, permissions, and payment processing
;; for IoT nodes on the LoopNode platform. It enables data consumers to request
;; access to node data, facilitates approval by node owners, and handles
;; payment processing and access control enforcement.

;; =====================================
;; Error Constants
;; =====================================
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-NODE-NOT-FOUND (err u101))
(define-constant ERR-REQUEST-NOT-FOUND (err u102))
(define-constant ERR-INVALID-PARAMETERS (err u103))
(define-constant ERR-INSUFFICIENT-FUNDS (err u104))
(define-constant ERR-REQUEST-ALREADY-PROCESSED (err u105))
(define-constant ERR-INVALID-STATE (err u106))
(define-constant ERR-ACCESS-EXPIRED (err u107))
(define-constant ERR-ACCESS-REVOKED (err u108))
(define-constant ERR-PAYMENT-FAILED (err u109))
(define-constant ERR-INVALID-PAYMENT-TYPE (err u110))

;; =====================================
;; Data Maps and Variables
;; =====================================

;; Links to the LoopNode Registry contract for node verification
(define-constant NODE-REGISTRY-CONTRACT .loopnode-registry)

;; Access request statuses
(define-constant STATUS-PENDING u1)
(define-constant STATUS-APPROVED u2)
(define-constant STATUS-DENIED u3)
(define-constant STATUS-REVOKED u4)
(define-constant STATUS-EXPIRED u5)

;; Payment types
(define-constant PAYMENT-TYPE-ONE-TIME u1)
(define-constant PAYMENT-TYPE-SUBSCRIPTION u2)

;; Maps a request ID to an access request
(define-map access-requests
  { request-id: uint }
  {
    requester: principal,
    node-id: uint,
    purpose: (string-ascii 100),
    start-block: uint,
    end-block: uint,
    payment-amount: uint,
    payment-type: uint,   ;; 1 = one-time, 2 = subscription
    payment-interval: uint,
    status: uint,
    approved-at: (optional uint),
    last-payment-block: (optional uint)
  }
)

;; Maps a node ID to a map of requesters who have access
(define-map node-access-permissions
  { node-id: uint, requester: principal }
  {
    request-id: uint,
    access-until-block: uint,
    is-revoked: bool
  }
)

;; Maps a node ID to the owner principal for quick access checks
(define-map node-owners
  { node-id: uint }
  { owner: principal }
)

;; Stores the total number of requests (used for generating request IDs)
(define-data-var request-counter uint u0)

;; =====================================
;; Private Functions
;; =====================================

;; Checks if the sender is the owner of the specified node
(define-private (is-node-owner (node-id uint) (sender principal))
  (match (get owner (map-get? node-owners { node-id: node-id }))
    owner (is-eq sender owner)
    false
  )
)

;; Gets the next request ID and increments the counter
(define-private (get-next-request-id)
  (let ((current-id (var-get request-counter)))
    (var-set request-counter (+ current-id u1))
    current-id
  )
)

;; Checks if an access request exists
(define-private (request-exists (request-id uint))
  (is-some (map-get? access-requests { request-id: request-id }))
)

;; Checks if access is still valid (not expired or revoked)
(define-private (is-access-valid (node-id uint) (requester principal))
  (match (map-get? node-access-permissions { node-id: node-id, requester: requester })
    permission (and 
                (not (get is-revoked permission))
                (<= block-height (get access-until-block permission)))
    false
  )
)

;; Processes payment for access (either one-time or subscription)
(define-private (process-payment (payer principal) (payee principal) (amount uint))
  (stx-transfer? amount payer payee)
)

;; Updates a request status
(define-private (update-request-status (request-id uint) (new-status uint))
  (match (map-get? access-requests { request-id: request-id })
    request (map-set access-requests 
                     { request-id: request-id }
                     (merge request { status: new-status }))
    false
  )
)

;; =====================================
;; Read-Only Functions
;; =====================================

;; Get details of an access request
(define-read-only (get-access-request (request-id uint))
  (map-get? access-requests { request-id: request-id })
)

;; Get all requests for a specific node
(define-read-only (get-node-requests (node-id uint))
  (map-get? access-requests { request-id: node-id })
)

;; Check if a requester has valid access to a node
(define-read-only (has-access (node-id uint) (requester principal))
  (is-access-valid node-id requester)
)

;; Get access permission details for a node-requester pair
(define-read-only (get-access-details (node-id uint) (requester principal))
  (map-get? node-access-permissions { node-id: node-id, requester: requester })
)

;; =====================================
;; Public Functions
;; =====================================

;; Register a node's owner from the registry contract
;; This would typically be called by the registry contract when a node is registered
(define-public (register-node-owner (node-id uint) (owner principal))
  (begin
    ;; Only the registry contract can call this function
    (asserts! (is-eq contract-caller NODE-REGISTRY-CONTRACT) ERR-NOT-AUTHORIZED)
    
    ;; Register the owner in our local map for quick lookups
    (map-set node-owners { node-id: node-id } { owner: owner })
    (ok true)
  )
)

;; Submit a request for access to node data
(define-public (request-access (node-id uint) 
                               (purpose (string-ascii 100))
                               (duration-blocks uint)
                               (payment-amount uint)
                               (payment-type uint)
                               (payment-interval uint))
  (let (
    (requester tx-sender)
    (request-id (get-next-request-id))
    (start-block block-height)
    (end-block (+ block-height duration-blocks))
  )
    ;; Verify node exists by checking owner
    (asserts! (is-some (map-get? node-owners { node-id: node-id })) ERR-NODE-NOT-FOUND)
    
    ;; Validate payment parameters
    (asserts! (> payment-amount u0) ERR-INVALID-PARAMETERS)
    (asserts! (or (is-eq payment-type PAYMENT-TYPE-ONE-TIME) 
                  (is-eq payment-type PAYMENT-TYPE-SUBSCRIPTION)) 
              ERR-INVALID-PAYMENT-TYPE)
    
    ;; If subscription, payment interval must be specified
    (asserts! (or (is-eq payment-type PAYMENT-TYPE-ONE-TIME) 
                  (> payment-interval u0))
              ERR-INVALID-PARAMETERS)
    
    ;; Record the access request
    (map-set access-requests
      { request-id: request-id }
      {
        requester: requester,
        node-id: node-id,
        purpose: purpose,
        start-block: start-block,
        end-block: end-block,
        payment-amount: payment-amount,
        payment-type: payment-type,
        payment-interval: payment-interval,
        status: STATUS-PENDING,
        approved-at: none,
        last-payment-block: none
      }
    )
    
    ;; Return the request ID
    (ok request-id)
  )
)

;; Approve an access request
(define-public (approve-access (request-id uint))
  (let (
    (sender tx-sender)
    (request (unwrap! (map-get? access-requests { request-id: request-id }) ERR-REQUEST-NOT-FOUND))
    (node-id (get node-id request))
    (requester (get requester request))
    (end-block (get end-block request))
    (payment-amount (get payment-amount request))
    (payment-type (get payment-type request))
  )
    ;; Verify the sender is the node owner
    (asserts! (is-node-owner node-id sender) ERR-NOT-AUTHORIZED)
    
    ;; Verify request is in pending status
    (asserts! (is-eq (get status request) STATUS-PENDING) ERR-REQUEST-ALREADY-PROCESSED)
    
    ;; Process payment based on payment type
    (if (is-eq payment-type PAYMENT-TYPE-ONE-TIME)
      ;; One-time payment
      (asserts! (is-ok (process-payment requester sender payment-amount)) ERR-PAYMENT-FAILED)
      ;; For subscription, initial payment will be processed on first access
      true
    )
    
    ;; Update request status to approved
    (map-set access-requests
      { request-id: request-id }
      (merge request {
        status: STATUS-APPROVED,
        approved-at: (some block-height),
        last-payment-block: (if (is-eq payment-type PAYMENT-TYPE-ONE-TIME) 
                              (some block-height)
                              none)
      })
    )
    
    ;; Grant access permissions
    (map-set node-access-permissions
      { node-id: node-id, requester: requester }
      {
        request-id: request-id,
        access-until-block: end-block,
        is-revoked: false
      }
    )
    
    (ok true)
  )
)

;; Deny an access request
(define-public (deny-access (request-id uint))
  (let (
    (sender tx-sender)
    (request (unwrap! (map-get? access-requests { request-id: request-id }) ERR-REQUEST-NOT-FOUND))
    (node-id (get node-id request))
  )
    ;; Verify the sender is the node owner
    (asserts! (is-node-owner node-id sender) ERR-NOT-AUTHORIZED)
    
    ;; Verify request is in pending status
    (asserts! (is-eq (get status request) STATUS-PENDING) ERR-REQUEST-ALREADY-PROCESSED)
    
    ;; Update request status to denied
    (update-request-status request-id STATUS-DENIED)
    
    (ok true)
  )
)

;; Revoke previously granted access
(define-public (revoke-access (node-id uint) (requester principal))
  (let (
    (sender tx-sender)
    (permission (unwrap! (map-get? node-access-permissions { node-id: node-id, requester: requester }) ERR-REQUEST-NOT-FOUND))
    (request-id (get request-id permission))
  )
    ;; Verify the sender is the node owner
    (asserts! (is-node-owner node-id sender) ERR-NOT-AUTHORIZED)
    
    ;; Update permission to revoked
    (map-set node-access-permissions
      { node-id: node-id, requester: requester }
      (merge permission { is-revoked: true })
    )
    
    ;; Update request status to revoked
    (update-request-status request-id STATUS-REVOKED)
    
    (ok true)
  )
)

;; Process a subscription payment
(define-public (process-subscription-payment (request-id uint))
  (let (
    (request (unwrap! (map-get? access-requests { request-id: request-id }) ERR-REQUEST-NOT-FOUND))
    (node-id (get node-id request))
    (requester (get requester request))
    (payment-amount (get payment-amount request))
    (payment-type (get payment-type request))
    (node-owner (get owner (unwrap! (map-get? node-owners { node-id: node-id }) ERR-NODE-NOT-FOUND)))
    (permission (unwrap! (map-get? node-access-permissions { node-id: node-id, requester: requester }) ERR-REQUEST-NOT-FOUND))
  )
    ;; Verify this is a subscription payment
    (asserts! (is-eq payment-type PAYMENT-TYPE-SUBSCRIPTION) ERR-INVALID-PAYMENT-TYPE)
    
    ;; Verify the sender is the requester
    (asserts! (is-eq tx-sender requester) ERR-NOT-AUTHORIZED)
    
    ;; Verify access is still valid (not revoked)
    (asserts! (not (get is-revoked permission)) ERR-ACCESS-REVOKED)
    
    ;; Process the payment
    (asserts! (is-ok (process-payment requester node-owner payment-amount)) ERR-PAYMENT-FAILED)
    
    ;; Update the last payment block
    (map-set access-requests
      { request-id: request-id }
      (merge request { last-payment-block: (some block-height) })
    )
    
    (ok true)
  )
)

;; Extend access duration
(define-public (extend-access (request-id uint) (additional-blocks uint))
  (let (
    (request (unwrap! (map-get? access-requests { request-id: request-id }) ERR-REQUEST-NOT-FOUND))
    (node-id (get node-id request))
    (requester (get requester request))
    (current-end-block (get end-block request))
    (payment-amount (get payment-amount request))
    (node-owner (get owner (unwrap! (map-get? node-owners { node-id: node-id }) ERR-NODE-NOT-FOUND)))
    (permission (unwrap! (map-get? node-access-permissions { node-id: node-id, requester: requester }) ERR-REQUEST-NOT-FOUND))
    (new-end-block (+ current-end-block additional-blocks))
  )
    ;; Verify the sender is the requester
    (asserts! (is-eq tx-sender requester) ERR-NOT-AUTHORIZED)
    
    ;; Verify access is not revoked
    (asserts! (not (get is-revoked permission)) ERR-ACCESS-REVOKED)
    
    ;; Calculate additional payment (proportional to original payment)
    (let (
      (original-duration (- (get end-block request) (get start-block request)))
      (extension-payment (/ (* payment-amount additional-blocks) original-duration))
    )
      ;; Process the extension payment
      (asserts! (is-ok (process-payment requester node-owner extension-payment)) ERR-PAYMENT-FAILED)
      
      ;; Update the request end block
      (map-set access-requests
        { request-id: request-id }
        (merge request { end-block: new-end-block })
      )
      
      ;; Update the access permission end block
      (map-set node-access-permissions
        { node-id: node-id, requester: requester }
        (merge permission { access-until-block: new-end-block })
      )
      
      (ok true)
    )
  )
)

;; Verify access (can be called by other contracts to check access rights)
(define-public (verify-access (node-id uint) (requester principal))
  (if (is-access-valid node-id requester)
    (ok true)
    ERR-NOT-AUTHORIZED
  )
)