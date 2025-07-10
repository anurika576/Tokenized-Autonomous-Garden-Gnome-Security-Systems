;; Theft Prevention Contract
;; Monitors decorative item displacement and unauthorized removal

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_GNOME_NOT_FOUND (err u201))
(define-constant ERR_ALERT_NOT_FOUND (err u202))
(define-constant ERR_INVALID_INPUT (err u203))
(define-constant ERR_ALREADY_REPORTED (err u204))

;; Alert severity levels
(define-constant SEVERITY_LOW u1)
(define-constant SEVERITY_MEDIUM u2)
(define-constant SEVERITY_HIGH u3)
(define-constant SEVERITY_CRITICAL u4)

;; Data Variables
(define-data-var alert-counter uint u0)
(define-data-var monitoring-enabled bool true)

;; Data Maps
(define-map theft-alerts
  { alert-id: uint }
  {
    gnome-id: uint,
    reporter: principal,
    alert-type: (string-ascii 50),
    severity: uint,
    description: (string-ascii 200),
    timestamp: uint,
    resolved: bool,
    resolver: (optional principal)
  }
)

(define-map gnome-monitoring
  { gnome-id: uint }
  {
    last-check: uint,
    displacement-count: uint,
    suspicious-activity: bool,
    monitoring-active: bool
  }
)

(define-map displacement-history
  { gnome-id: uint, sequence: uint }
  {
    old-x: uint,
    old-y: uint,
    new-x: uint,
    new-y: uint,
    timestamp: uint,
    authorized: bool
  }
)

(define-map reporter-stats
  { reporter: principal }
  {
    total-reports: uint,
    verified-reports: uint,
    false-reports: uint,
    reputation-score: uint
  }
)

;; Public Functions

;; Report theft or suspicious activity
(define-public (report-theft (gnome-id uint) (alert-type (string-ascii 50)) (description (string-ascii 200)))
  (let
    (
      (new-alert-id (+ (var-get alert-counter) u1))
      (caller tx-sender)
      (current-time block-height)
    )
    ;; Validate input
    (asserts! (> (len alert-type) u0) ERR_INVALID_INPUT)
    (asserts! (> (len description) u0) ERR_INVALID_INPUT)

    ;; Create theft alert
    (map-set theft-alerts
      { alert-id: new-alert-id }
      {
        gnome-id: gnome-id,
        reporter: caller,
        alert-type: alert-type,
        severity: (calculate-severity alert-type),
        description: description,
        timestamp: current-time,
        resolved: false,
        resolver: none
      }
    )

    ;; Update gnome monitoring status
    (let
      (
        (monitoring-data (default-to
          { last-check: u0, displacement-count: u0, suspicious-activity: false, monitoring-active: true }
          (map-get? gnome-monitoring { gnome-id: gnome-id })
        ))
      )
      (map-set gnome-monitoring
        { gnome-id: gnome-id }
        (merge monitoring-data {
          last-check: current-time,
          suspicious-activity: true
        })
      )
    )

    ;; Update reporter statistics
    (update-reporter-stats caller true)

    ;; Update counter
    (var-set alert-counter new-alert-id)

    (ok new-alert-id)
  )
)

;; Record authorized displacement
(define-public (record-displacement (gnome-id uint) (old-x uint) (old-y uint) (new-x uint) (new-y uint))
  (let
    (
      (caller tx-sender)
      (current-time block-height)
      (monitoring-data (default-to
        { last-check: u0, displacement-count: u0, suspicious-activity: false, monitoring-active: true }
        (map-get? gnome-monitoring { gnome-id: gnome-id })
      ))
      (new-sequence (+ (get displacement-count monitoring-data) u1))
    )
    ;; Record displacement in history
    (map-set displacement-history
      { gnome-id: gnome-id, sequence: new-sequence }
      {
        old-x: old-x,
        old-y: old-y,
        new-x: new-x,
        new-y: new-y,
        timestamp: current-time,
        authorized: true
      }
    )

    ;; Update monitoring data
    (map-set gnome-monitoring
      { gnome-id: gnome-id }
      (merge monitoring-data {
        last-check: current-time,
        displacement-count: new-sequence
      })
    )

    (ok true)
  )
)

;; Resolve theft alert
(define-public (resolve-alert (alert-id uint) (verified bool))
  (let
    (
      (alert-data (unwrap! (map-get? theft-alerts { alert-id: alert-id }) ERR_ALERT_NOT_FOUND))
      (caller tx-sender)
    )
    ;; Update alert status
    (map-set theft-alerts
      { alert-id: alert-id }
      (merge alert-data {
        resolved: true,
        resolver: (some caller)
      })
    )

    ;; Update reporter statistics
    (update-reporter-stats (get reporter alert-data) verified)

    (ok true)
  )
)

;; Enable/disable monitoring for a gnome
(define-public (toggle-monitoring (gnome-id uint) (enabled bool))
  (let
    (
      (monitoring-data (default-to
        { last-check: u0, displacement-count: u0, suspicious-activity: false, monitoring-active: true }
        (map-get? gnome-monitoring { gnome-id: gnome-id })
      ))
    )
    (map-set gnome-monitoring
      { gnome-id: gnome-id }
      (merge monitoring-data { monitoring-active: enabled })
    )

    (ok true)
  )
)

;; Private Functions

;; Calculate alert severity based on type
(define-private (calculate-severity (alert-type (string-ascii 50)))
  (if (is-eq alert-type "theft")
    SEVERITY_CRITICAL
    (if (is-eq alert-type "displacement")
      SEVERITY_MEDIUM
      (if (is-eq alert-type "vandalism")
        SEVERITY_HIGH
        SEVERITY_LOW
      )
    )
  )
)

;; Update reporter statistics
(define-private (update-reporter-stats (reporter principal) (verified bool))
  (let
    (
      (current-stats (default-to
        { total-reports: u0, verified-reports: u0, false-reports: u0, reputation-score: u100 }
        (map-get? reporter-stats { reporter: reporter })
      ))
      (new-total (+ (get total-reports current-stats) u1))
      (new-verified (if verified (+ (get verified-reports current-stats) u1) (get verified-reports current-stats)))
      (new-false (if verified (get false-reports current-stats) (+ (get false-reports current-stats) u1)))
      (new-score (calculate-reputation-score new-verified new-false new-total))
    )
    (map-set reporter-stats
      { reporter: reporter }
      {
        total-reports: new-total,
        verified-reports: new-verified,
        false-reports: new-false,
        reputation-score: new-score
      }
    )
  )
)

;; Calculate reputation score
(define-private (calculate-reputation-score (verified uint) (false-reports uint) (total uint))
  (if (is-eq total u0)
    u100
    (let
      (
        (accuracy-rate (/ (* verified u100) total))
        (penalty (if (> false-reports u0) (/ (* false-reports u20) total) u0))
      )
      (if (>= accuracy-rate penalty)
        (- accuracy-rate penalty)
        u0
      )
    )
  )
)

;; Read-only Functions

;; Get theft alert details
(define-read-only (get-alert (alert-id uint))
  (map-get? theft-alerts { alert-id: alert-id })
)

;; Get gnome monitoring status
(define-read-only (get-monitoring-status (gnome-id uint))
  (map-get? gnome-monitoring { gnome-id: gnome-id })
)

;; Get displacement history
(define-read-only (get-displacement-history (gnome-id uint) (sequence uint))
  (map-get? displacement-history { gnome-id: gnome-id, sequence: sequence })
)

;; Get reporter statistics
(define-read-only (get-reporter-stats (reporter principal))
  (map-get? reporter-stats { reporter: reporter })
)

;; Get total alert count
(define-read-only (get-alert-count)
  (var-get alert-counter)
)

;; Check if monitoring is globally enabled
(define-read-only (is-monitoring-enabled)
  (var-get monitoring-enabled)
)
