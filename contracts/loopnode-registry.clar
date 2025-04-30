;; LoopNode Registry Contract
;; This contract serves as the central registry for the LoopNode ecosystem, allowing IoT device owners to register
;; their nodes with important metadata and manage access permissions. It enables discovery of IoT nodes by data consumers
;; and tracks node reputation and verification status.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-NODE-NOT-FOUND (err u101))
(define-constant ERR-NODE-ALREADY-EXISTS (err u102))
(define-constant ERR-INVALID-STATUS (err u103))
(define-constant ERR-NODE-INACTIVE (err u104))
(define-constant ERR-RATING-OUT-OF-RANGE (err u105))

;; Node status constants
(define-constant NODE-STATUS-ACTIVE u1)
(define-constant NODE-STATUS-INACTIVE u2)
(define-constant NODE-STATUS-MAINTENANCE u3)

;; Data structures

;; Stores the total number of registered nodes
(define-data-var node-counter uint u0)

;; Maps node-id to node-owner
(define-map node-owners uint principal)

;; Maps node-id to node-metadata
(define-map node-metadata uint 
  {
    name: (string-ascii 100),
    description: (string-ascii 500),
    location: (string-ascii 100),
    capabilities: (string-ascii 500),
    data-types: (string-ascii 500),
    refresh-rate: uint,
    status: uint,
    verification-status: bool,
    price-per-request: uint,
    registration-time: uint
  }
)

;; Maps node-id to reputation metrics
(define-map node-reputation uint
  {
    total-ratings: uint,
    rating-sum: uint,
    average-rating: uint,
    uptime-percentage: uint
  }
)

;; Maps principal to list of node-ids they own
(define-map user-nodes principal (list 50 uint))

;; Maps rater principal and node-id to rating value to prevent duplicate ratings
(define-map node-ratings {rater: principal, node-id: uint} uint)

;; Private functions

;; Get the next available node ID and increment the counter
(define-private (get-next-node-id)
  (let ((current-id (var-get node-counter)))
    (var-set node-counter (+ current-id u1))
    current-id))

;; Add a node ID to a user's list of owned nodes
(define-private (add-node-to-user-list (node-id uint) (owner principal))
  (let ((current-nodes (default-to (list) (map-get? user-nodes owner))))
    (map-set user-nodes owner (append current-nodes node-id))))

;; Check if a principal is the owner of a specific node
(define-private (is-node-owner (node-id uint) (owner principal))
  (match (map-get? node-owners node-id)
    owner true
    _ false))

;; Initialize a new node's reputation
(define-private (init-node-reputation (node-id uint))
  (map-set node-reputation node-id
    {
      total-ratings: u0,
      rating-sum: u0,
      average-rating: u0,
      uptime-percentage: u100
    }))

;; Read-only functions

;; Get node metadata by ID
(define-read-only (get-node-metadata (node-id uint))
  (map-get? node-metadata node-id))

;; Get node owner by ID
(define-read-only (get-node-owner (node-id uint))
  (map-get? node-owners node-id))

;; Get node reputation by ID
(define-read-only (get-node-reputation (node-id uint))
  (map-get? node-reputation node-id))

;; Get all nodes owned by a user
(define-read-only (get-user-nodes (user principal))
  (default-to (list) (map-get? user-nodes user)))

;; Check if a node is active
(define-read-only (is-node-active (node-id uint))
  (match (map-get? node-metadata node-id)
    metadata (is-eq (get status metadata) NODE-STATUS-ACTIVE)
    false))

;; Check if a user has already rated a node
(define-read-only (has-rated-node (user principal) (node-id uint))
  (is-some (map-get? node-ratings {rater: user, node-id: node-id})))

;; Get the total number of registered nodes
(define-read-only (get-node-count)
  (var-get node-counter))

;; Public functions

;; Register a new IoT node with metadata
(define-public (register-node
    (name (string-ascii 100))
    (description (string-ascii 500))
    (location (string-ascii 100))
    (capabilities (string-ascii 500))
    (data-types (string-ascii 500))
    (refresh-rate uint)
    (price-per-request uint))
  (let
    ((node-id (get-next-node-id))
     (owner tx-sender))
    
    ;; Store node owner
    (map-set node-owners node-id owner)
    
    ;; Store node metadata
    (map-set node-metadata node-id
      {
        name: name,
        description: description,
        location: location,
        capabilities: capabilities,
        data-types: data-types,
        refresh-rate: refresh-rate,
        status: NODE-STATUS-ACTIVE,
        verification-status: false,
        price-per-request: price-per-request,
        registration-time: block-height
      })
    
    ;; Initialize node reputation
    (init-node-reputation node-id)
    
    ;; Add node to user's list
    (add-node-to-user-list node-id owner)
    
    ;; Return the new node ID
    (ok node-id)))

;; Update node metadata (only by owner)
(define-public (update-node-metadata
    (node-id uint)
    (name (string-ascii 100))
    (description (string-ascii 500))
    (location (string-ascii 100))
    (capabilities (string-ascii 500))
    (data-types (string-ascii 500))
    (refresh-rate uint)
    (price-per-request uint))
  (let ((owner tx-sender))
    
    ;; Check if node exists and caller is owner
    (asserts! (is-some (map-get? node-owners node-id)) ERR-NODE-NOT-FOUND)
    (asserts! (is-node-owner node-id owner) ERR-NOT-AUTHORIZED)
    
    ;; Get current metadata to preserve status and verification
    (match (map-get? node-metadata node-id)
      metadata
        (map-set node-metadata node-id
          {
            name: name,
            description: description,
            location: location,
            capabilities: capabilities,
            data-types: data-types,
            refresh-rate: refresh-rate,
            status: (get status metadata),
            verification-status: (get verification-status metadata),
            price-per-request: price-per-request,
            registration-time: (get registration-time metadata)
          })
      ERR-NODE-NOT-FOUND)
    
    (ok true)))

;; Update node status (active, inactive, maintenance)
(define-public (update-node-status (node-id uint) (new-status uint))
  (let ((owner tx-sender))
    
    ;; Check if node exists and caller is owner
    (asserts! (is-some (map-get? node-owners node-id)) ERR-NODE-NOT-FOUND)
    (asserts! (is-node-owner node-id owner) ERR-NOT-AUTHORIZED)
    
    ;; Check if status is valid
    (asserts! (or (is-eq new-status NODE-STATUS-ACTIVE)
                 (is-eq new-status NODE-STATUS-INACTIVE)
                 (is-eq new-status NODE-STATUS-MAINTENANCE))
             ERR-INVALID-STATUS)
    
    ;; Update status while preserving other metadata
    (match (map-get? node-metadata node-id)
      metadata
        (map-set node-metadata node-id
          (merge metadata {status: new-status}))
      ERR-NODE-NOT-FOUND)
    
    (ok true)))

;; Set node verification status (admin function)
;; In a real implementation, this would be restricted to contract-owner or a multi-sig approach
(define-public (set-verification-status (node-id uint) (status bool))
  (let ((admin tx-sender))
    
    ;; In a real implementation, add admin check here
    ;; For now, allowing any user (simplified for demo purposes)
    
    ;; Check if node exists
    (asserts! (is-some (map-get? node-metadata node-id)) ERR-NODE-NOT-FOUND)
    
    ;; Update verification status
    (match (map-get? node-metadata node-id)
      metadata
        (map-set node-metadata node-id
          (merge metadata {verification-status: status}))
      ERR-NODE-NOT-FOUND)
    
    (ok true)))

;; Rate a node (any user who has interacted with the node)
(define-public (rate-node (node-id uint) (rating uint))
  (let ((rater tx-sender))
    
    ;; Check if node exists and is active
    (asserts! (is-some (map-get? node-metadata node-id)) ERR-NODE-NOT-FOUND)
    (asserts! (is-node-active node-id) ERR-NODE-INACTIVE)
    
    ;; Check if rating is in valid range (1-5)
    (asserts! (and (>= rating u1) (<= rating u5)) ERR-RATING-OUT-OF-RANGE)
    
    ;; Check if user has already rated this node
    (asserts! (not (has-rated-node rater node-id)) ERR-NOT-AUTHORIZED)
    
    ;; Record this rating
    (map-set node-ratings {rater: rater, node-id: node-id} rating)
    
    ;; Update node reputation
    (match (map-get? node-reputation node-id)
      rep
        (let
          ((new-total (+ (get total-ratings rep) u1))
           (new-sum (+ (get rating-sum rep) rating))
           (new-avg (/ new-sum new-total)))
          
          (map-set node-reputation node-id
            {
              total-ratings: new-total,
              rating-sum: new-sum,
              average-rating: new-avg,
              uptime-percentage: (get uptime-percentage rep)
            }))
      ERR-NODE-NOT-FOUND)
    
    (ok true)))

;; Update node uptime percentage (this would typically be called by a trusted oracle)
(define-public (update-node-uptime (node-id uint) (uptime uint))
  (let ((caller tx-sender))
    
    ;; Check if node exists
    (asserts! (is-some (map-get? node-metadata node-id)) ERR-NODE-NOT-FOUND)
    
    ;; Check if caller is node owner
    (asserts! (is-node-owner node-id caller) ERR-NOT-AUTHORIZED)
    
    ;; Check if uptime is valid (0-100)
    (asserts! (<= uptime u100) ERR-RATING-OUT-OF-RANGE)
    
    ;; Update uptime
    (match (map-get? node-reputation node-id)
      rep
        (map-set node-reputation node-id
          (merge rep {uptime-percentage: uptime}))
      ERR-NODE-NOT-FOUND)
    
    (ok true)))

;; Delete a node (only by owner)
(define-public (delete-node (node-id uint))
  (let ((owner tx-sender))
    
    ;; Check if node exists and caller is owner
    (asserts! (is-some (map-get? node-owners node-id)) ERR-NODE-NOT-FOUND)
    (asserts! (is-node-owner node-id owner) ERR-NOT-AUTHORIZED)
    
    ;; Remove node owner mapping
    (map-delete node-owners node-id)
    
    ;; Remove node metadata
    (map-delete node-metadata node-id)
    
    ;; Remove node reputation
    (map-delete node-reputation node-id)
    
    ;; Update user's node list
    (match (map-get? user-nodes owner)
      nodes
        (let
          ((new-nodes (filter (lambda (id) (not (is-eq id node-id))) nodes)))
          (map-set user-nodes owner new-nodes))
      false)
    
    (ok true)))