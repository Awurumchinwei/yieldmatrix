;; Yield Matrix - Advanced Yield Aggregator with Auto-Compounding
;; Features: Multi-strategy vaults, risk scoring, automated rebalancing, profit sharing

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-unauthorized (err u100))
(define-constant err-insufficient-balance (err u101))
(define-constant err-vault-not-found (err u102))
(define-constant err-strategy-not-found (err u103))
(define-constant err-max-capacity (err u104))
(define-constant err-min-deposit (err u105))
(define-constant err-cooldown-active (err u106))
(define-constant err-paused (err u107))
(define-constant err-invalid-amount (err u108))
(define-constant err-strategy-failed (err u109))
(define-constant err-already-exists (err u110))
(define-constant err-zero-shares (err u111))
(define-constant err-locked (err u112))

;; Protocol Parameters
(define-constant min-deposit-amount u1000000) ;; 1 STX minimum
(define-constant performance-fee u2000) ;; 20% performance fee
(define-constant management-fee u200) ;; 2% annual management fee
(define-constant withdrawal-fee u50) ;; 0.5% withdrawal fee
(define-constant compound-bounty u100) ;; 1% bounty for compound callers
(define-constant max-strategies-per-vault u5)
(define-constant cooldown-period u144) ;; ~24 hours
(define-constant rebalance-threshold u500) ;; 5% deviation triggers rebalance
(define-constant emergency-withdrawal-penalty u1000) ;; 10% emergency penalty

;; Data Variables
(define-data-var vault-counter uint u0)
(define-data-var strategy-counter uint u0)
(define-data-var total-tvl uint u0)
(define-data-var total-rewards-distributed uint u0)
(define-data-var protocol-fees-earned uint u0)
(define-data-var global-paused bool false)
(define-data-var last-harvest-block uint u0)

;; Data Maps
(define-map vaults
    uint ;; vault-id
    {
        name: (string-ascii 50),
        asset: principal,
        total-shares: uint,
        total-assets: uint,
        available-assets: uint,
        locked-profit: uint,
        last-harvest: uint,
        performance-fee: uint,
        management-fee: uint,
        is-active: bool,
        max-capacity: uint,
        strategy-count: uint
    })

(define-map user-shares
    { vault-id: uint, user: principal }
    {
        shares: uint,
        deposited-amount: uint,
        last-deposit-block: uint,
        locked-until: uint,
        profit-claimed: uint
    })

(define-map strategies
    uint ;; strategy-id
    {
        name: (string-ascii 50),
        vault-id: uint,
        allocation-percentage: uint,
        deployed-capital: uint,
        total-returns: uint,
        risk-score: uint,
        is-active: bool,
        last-update: uint,
        min-deployment: uint,
        max-deployment: uint
    })

(define-map vault-strategies
    { vault-id: uint, strategy-id: uint }
    {
        is-enabled: bool,
        current-allocation: uint,
        target-allocation: uint,
        total-gains: uint,
        total-losses: uint
    })

(define-map harvest-log
    { vault-id: uint, harvest-id: uint }
    {
        block-height: uint,
        total-profit: uint,
        performance-fee-paid: uint,
        compound-bounty-paid: uint,
        harvester: principal
    })

(define-map user-rewards
    principal
    {
        total-earned: uint,
        pending-rewards: uint,
        last-claim-block: uint,
        compound-bounties: uint,
        referral-rewards: uint
    })

(define-map risk-parameters
    uint ;; vault-id
    {
        max-drawdown: uint,
        volatility-score: uint,
        sharpe-ratio: uint,
        risk-level: (string-ascii 20)
    })

(define-map epoch-data
    { vault-id: uint, epoch: uint }
    {
        start-block: uint,
        end-block: uint,
        epoch-profit: uint,
        epoch-loss: uint,
        active-users: uint
    })

;; Private Functions
(define-private (calculate-shares (amount uint) (total-assets uint) (total-shares uint))
    (if (is-eq total-shares u0)
        amount
        (/ (* amount total-shares) total-assets)))

(define-private (calculate-assets (shares uint) (total-shares uint) (total-assets uint))
    (if (is-eq total-shares u0)
        u0
        (/ (* shares total-assets) total-shares)))

(define-private (calculate-performance-fee (profit uint) (fee-rate uint))
    (/ (* profit fee-rate) u10000))

(define-private (calculate-management-fee (assets uint) (fee-rate uint) (blocks uint))
    (/ (* (* assets fee-rate) blocks) (* u52560 u10000)))

(define-private (min-uint (a uint) (b uint))
    (if (<= a b) a b))

(define-private (calculate-risk-score (volatility uint) (drawdown uint))
    (let ((base-score u1000))
        (- base-score (+ (/ volatility u10) (/ drawdown u5)))))

(define-private (should-rebalance (current-allocation uint) (target-allocation uint))
    (let ((deviation (if (> current-allocation target-allocation)
                        (- current-allocation target-allocation)
                        (- target-allocation current-allocation))))
        (> deviation rebalance-threshold)))

;; Read-only Functions
(define-read-only (get-vault (vault-id uint))
    (ok (map-get? vaults vault-id)))

(define-read-only (get-user-balance (vault-id uint) (user principal))
    (match (map-get? user-shares { vault-id: vault-id, user: user })
        user-data (match (map-get? vaults vault-id)
                    vault (ok (calculate-assets (get shares user-data)
                                              (get total-shares vault)
                                              (get total-assets vault)))
                    (err err-vault-not-found))
        (ok u0)))

(define-read-only (get-strategy (strategy-id uint))
    (ok (map-get? strategies strategy-id)))

(define-read-only (get-vault-apy (vault-id uint))
    (match (map-get? vaults vault-id)
        vault (let ((blocks-per-year u52560)
                   (time-elapsed (- burn-block-height (get last-harvest vault)))
                   (profit (get locked-profit vault)))
               (if (and (> time-elapsed u0) (> (get total-assets vault) u0))
                   (ok (/ (* (* profit blocks-per-year) u10000) 
                         (* (get total-assets vault) time-elapsed)))
                   (ok u0)))
        (err err-vault-not-found)))

(define-read-only (get-user-rewards (user principal))
    (ok (map-get? user-rewards user)))

(define-read-only (get-risk-parameters (vault-id uint))
    (ok (map-get? risk-parameters vault-id)))

(define-read-only (get-total-tvl)
    (ok (var-get total-tvl)))

(define-read-only (get-protocol-stats)
    (ok {
        total-vaults: (var-get vault-counter),
        total-strategies: (var-get strategy-counter),
        total-tvl: (var-get total-tvl),
        total-rewards: (var-get total-rewards-distributed),
        protocol-fees: (var-get protocol-fees-earned),
        is-paused: (var-get global-paused)
    }))

;; Public Functions
(define-public (create-vault (name (string-ascii 50)) 
                            (asset principal)
                            (max-capacity uint))
    (let ((vault-id (+ (var-get vault-counter) u1)))
        ;; Validations
        (asserts! (not (var-get global-paused)) err-paused)
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        
        ;; Create vault
        (map-set vaults vault-id {
            name: name,
            asset: asset,
            total-shares: u0,
            total-assets: u0,
            available-assets: u0,
            locked-profit: u0,
            last-harvest: burn-block-height,
            performance-fee: performance-fee,
            management-fee: management-fee,
            is-active: true,
            max-capacity: max-capacity,
            strategy-count: u0
        })
        
        ;; Initialize risk parameters
        (map-set risk-parameters vault-id {
            max-drawdown: u0,
            volatility-score: u500,
            sharpe-ratio: u100,
            risk-level: "moderate"
        })
        
        ;; Update counter
        (var-set vault-counter vault-id)
        
        (ok vault-id)))

(define-public (deposit (vault-id uint) (amount uint))
    (let ((vault (unwrap! (map-get? vaults vault-id) err-vault-not-found))
          (user-data (default-to { shares: u0, deposited-amount: u0, 
                                  last-deposit-block: u0, locked-until: u0, 
                                  profit-claimed: u0 }
                                (map-get? user-shares { vault-id: vault-id, user: tx-sender }))))
        
        ;; Validations
        (asserts! (not (var-get global-paused)) err-paused)
        (asserts! (get is-active vault) err-paused)
        (asserts! (>= amount min-deposit-amount) err-min-deposit)
        (asserts! (<= (+ (get total-assets vault) amount) (get max-capacity vault)) err-max-capacity)
        
        ;; Calculate shares to mint
        (let ((shares-to-mint (calculate-shares amount 
                                               (get total-assets vault) 
                                               (get total-shares vault))))
            
            ;; Transfer assets
            (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
            
            ;; Update user shares
            (map-set user-shares 
                    { vault-id: vault-id, user: tx-sender }
                    {
                        shares: (+ (get shares user-data) shares-to-mint),
                        deposited-amount: (+ (get deposited-amount user-data) amount),
                        last-deposit-block: burn-block-height,
                        locked-until: (+ burn-block-height cooldown-period),
                        profit-claimed: (get profit-claimed user-data)
                    })
            
            ;; Update vault
            (map-set vaults vault-id
                    (merge vault {
                        total-shares: (+ (get total-shares vault) shares-to-mint),
                        total-assets: (+ (get total-assets vault) amount),
                        available-assets: (+ (get available-assets vault) amount)
                    }))
            
            ;; Update TVL
            (var-set total-tvl (+ (var-get total-tvl) amount))
            
            (ok shares-to-mint))))

(define-public (withdraw (vault-id uint) (shares uint))
    (let ((vault (unwrap! (map-get? vaults vault-id) err-vault-not-found))
          (user-data (unwrap! (map-get? user-shares { vault-id: vault-id, user: tx-sender })
                            err-insufficient-balance)))
        
        ;; Validations
        (asserts! (not (var-get global-paused)) err-paused)
        (asserts! (<= shares (get shares user-data)) err-insufficient-balance)
        (asserts! (> burn-block-height (get locked-until user-data)) err-cooldown-active)
        (asserts! (> shares u0) err-zero-shares)
        
        ;; Calculate assets to return
        (let ((assets-to-return (calculate-assets shares 
                                                 (get total-shares vault) 
                                                 (get total-assets vault)))
              (fee (/ (* assets-to-return withdrawal-fee) u10000))
              (net-assets (- assets-to-return fee)))
            
            ;; Transfer assets
            (try! (as-contract (stx-transfer? net-assets tx-sender tx-sender)))
            
            ;; Update user shares
            (if (is-eq shares (get shares user-data))
                ;; Remove user if withdrawing all
                (map-delete user-shares { vault-id: vault-id, user: tx-sender })
                ;; Update remaining shares
                (map-set user-shares 
                        { vault-id: vault-id, user: tx-sender }
                        (merge user-data {
                            shares: (- (get shares user-data) shares)
                        })))
            
            ;; Update vault
            (map-set vaults vault-id
                    (merge vault {
                        total-shares: (- (get total-shares vault) shares),
                        total-assets: (- (get total-assets vault) assets-to-return),
                        available-assets: (- (get available-assets vault) assets-to-return)
                    }))
            
            ;; Update TVL and fees
            (var-set total-tvl (- (var-get total-tvl) assets-to-return))
            (var-set protocol-fees-earned (+ (var-get protocol-fees-earned) fee))
            
            (ok net-assets))))

(define-public (harvest (vault-id uint))
    (let ((vault (unwrap! (map-get? vaults vault-id) err-vault-not-found)))
        
        ;; Calculate time-based fees
        (let ((blocks-elapsed (- burn-block-height (get last-harvest vault)))
              (mgmt-fee (calculate-management-fee (get total-assets vault) 
                                                 (get management-fee vault) 
                                                 blocks-elapsed))
              ;; Simulated profit (in production, would aggregate from strategies)
              (gross-profit (/ (* (get total-assets vault) u1000) u10000)) ;; 10% simulated
              (perf-fee (calculate-performance-fee gross-profit (get performance-fee vault)))
              (bounty (/ (* gross-profit compound-bounty) u10000))
              (net-profit (- (- gross-profit perf-fee) bounty)))
            
            ;; Pay compound bounty to caller
            (try! (as-contract (stx-transfer? bounty tx-sender tx-sender)))
            
            ;; Update vault with profits
            (map-set vaults vault-id
                    (merge vault {
                        total-assets: (+ (get total-assets vault) net-profit),
                        locked-profit: net-profit,
                        last-harvest: burn-block-height
                    }))
            
            ;; Log harvest
            (map-set harvest-log 
                    { vault-id: vault-id, harvest-id: burn-block-height }
                    {
                        block-height: burn-block-height,
                        total-profit: gross-profit,
                        performance-fee-paid: perf-fee,
                        compound-bounty-paid: bounty,
                        harvester: tx-sender
                    })
            
            ;; Update user rewards for harvester
            (match (map-get? user-rewards tx-sender)
                rewards (map-set user-rewards tx-sender
                              (merge rewards {
                                  compound-bounties: (+ (get compound-bounties rewards) bounty)
                              }))
                (map-set user-rewards tx-sender {
                    total-earned: bounty,
                    pending-rewards: u0,
                    last-claim-block: burn-block-height,
                    compound-bounties: bounty,
                    referral-rewards: u0
                }))
            
            ;; Update global stats
            (var-set total-rewards-distributed (+ (var-get total-rewards-distributed) net-profit))
            (var-set protocol-fees-earned (+ (var-get protocol-fees-earned) (+ perf-fee mgmt-fee)))
            (var-set last-harvest-block burn-block-height)
            
            (ok net-profit))))

(define-public (add-strategy (vault-id uint)
                            (name (string-ascii 50))
                            (allocation-percentage uint)
                            (risk-score uint))
    (let ((strategy-id (+ (var-get strategy-counter) u1))
          (vault (unwrap! (map-get? vaults vault-id) err-vault-not-found)))
        
        ;; Validations
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (< (get strategy-count vault) max-strategies-per-vault) err-max-capacity)
        (asserts! (<= allocation-percentage u10000) err-invalid-amount)
        
        ;; Create strategy
        (map-set strategies strategy-id {
            name: name,
            vault-id: vault-id,
            allocation-percentage: allocation-percentage,
            deployed-capital: u0,
            total-returns: u0,
            risk-score: risk-score,
            is-active: true,
            last-update: burn-block-height,
            min-deployment: u1000000,
            max-deployment: u1000000000
        })
        
        ;; Link strategy to vault
        (map-set vault-strategies 
                { vault-id: vault-id, strategy-id: strategy-id }
                {
                    is-enabled: true,
                    current-allocation: u0,
                    target-allocation: allocation-percentage,
                    total-gains: u0,
                    total-losses: u0
                })
        
        ;; Update vault
        (map-set vaults vault-id
                (merge vault {
                    strategy-count: (+ (get strategy-count vault) u1)
                }))
        
        ;; Update counter
        (var-set strategy-counter strategy-id)
        
        (ok strategy-id)))

(define-public (rebalance (vault-id uint))
    (let ((vault (unwrap! (map-get? vaults vault-id) err-vault-not-found)))
        
        ;; Check if rebalancing is needed
        ;; In production, would iterate through strategies and rebalance
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        
        ;; Simulated rebalancing logic
        (let ((available (get available-assets vault))
              (to-deploy (/ available u2))) ;; Deploy 50% to strategies
            
            ;; Update vault
            (map-set vaults vault-id
                    (merge vault {
                        available-assets: (- available to-deploy)
                    }))
            
            (ok true))))

(define-public (emergency-withdraw (vault-id uint))
    (let ((vault (unwrap! (map-get? vaults vault-id) err-vault-not-found))
          (user-data (unwrap! (map-get? user-shares { vault-id: vault-id, user: tx-sender })
                            err-insufficient-balance)))
        
        ;; Calculate emergency withdrawal
        (let ((shares (get shares user-data))
              (assets (calculate-assets shares 
                                      (get total-shares vault) 
                                      (get total-assets vault)))
              (penalty (/ (* assets emergency-withdrawal-penalty) u10000))
              (net-assets (- assets penalty)))
            
            ;; Transfer with penalty
            (try! (as-contract (stx-transfer? net-assets tx-sender tx-sender)))
            
            ;; Remove user shares
            (map-delete user-shares { vault-id: vault-id, user: tx-sender })
            
            ;; Update vault
            (map-set vaults vault-id
                    (merge vault {
                        total-shares: (- (get total-shares vault) shares),
                        total-assets: (- (get total-assets vault) assets)
                    }))
            
            ;; Update stats
            (var-set total-tvl (- (var-get total-tvl) assets))
            (var-set protocol-fees-earned (+ (var-get protocol-fees-earned) penalty))
            
            (ok net-assets))))

(define-public (update-risk-parameters (vault-id uint)
                                      (max-drawdown uint)
                                      (volatility uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (is-some (map-get? vaults vault-id)) err-vault-not-found)
        
        (let ((risk-score (calculate-risk-score volatility max-drawdown))
              (risk-level (if (>= risk-score u800) "low"
                            (if (>= risk-score u500) "moderate"
                                "high"))))
            
            (map-set risk-parameters vault-id {
                max-drawdown: max-drawdown,
                volatility-score: volatility,
                sharpe-ratio: (/ risk-score u10),
                risk-level: risk-level
            })
            
            (ok true))))

;; Admin Functions
(define-public (pause-protocol)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (var-set global-paused true)
        (ok true)))

(define-public (unpause-protocol)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (var-set global-paused false)
        (ok true)))

(define-public (set-vault-fees (vault-id uint) (perf-fee uint) (mgmt-fee uint))
    (let ((vault (unwrap! (map-get? vaults vault-id) err-vault-not-found)))
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (<= perf-fee u5000) err-invalid-amount) ;; Max 50%
        (asserts! (<= mgmt-fee u1000) err-invalid-amount) ;; Max 10%
        
        (map-set vaults vault-id
                (merge vault {
                    performance-fee: perf-fee,
                    management-fee: mgmt-fee
                }))
        
        (ok true)))

(define-public (withdraw-protocol-fees (amount uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (<= amount (var-get protocol-fees-earned)) err-insufficient-balance)
        
        (try! (as-contract (stx-transfer? amount tx-sender contract-owner)))
        (var-set protocol-fees-earned (- (var-get protocol-fees-earned) amount))
        
        (ok amount)))