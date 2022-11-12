
// Copyright 2022  Authors. Licensed under Apache-2.0 License.
module Stream::streampay {
    use std::signer;
    use std::error;
    use std::vector;
    use std::string::{Self, String};
    
    use aptos_std::event::{Self, EventHandle};
    use aptos_std::type_info;
    use aptos_std::table::{Self, Table};

    use aptos_framework::account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;

    const MIN_DEPOSIT_BALANCE: u64 = 10000; // 0.0001 APT(decimals=8)
    const INIT_FEE_POINT: u8 = 250; // 2.5%

    const STREAM_HAS_PUBLISHED: u64 = 1;
    const STREAM_NOT_PUBLISHED: u64 = 2;
    const STREAM_PERMISSION_DENIED: u64 = 3;
    const STREAM_INSUFFICIENT_BALANCES: u64 = 4;
    const STREAM_NOT_FOUND: u64 = 5;
    const STREAM_BALANCE_TOO_LITTLE: u64 = 6;
    const STREAM_HAS_REGISTERED: u64 = 7;
    const STREAM_COIN_TYPE_MISMATCH: u64 = 8;
    const STREAM_NOT_START: u64 = 9;
    const STREAM_EXCEED_STOP_TIME: u64 = 10;
    const STREAM_IS_CLOSE: u64 = 11;

    const EVENT_TYPE_CREATE: u8 = 0;
    const EVENT_TYPE_WITHDRAW: u8 = 1;
    const EVENT_TYPE_CLOSE: u8 = 2;


    /// Event emitted when created/withdraw/closed a streampay
    struct StreamEvent has drop, store {
        id: u64,
        coin_id: u64,
        event_type: u8,
        remaining_balance: u64,
    }

    struct ConfigEvent has drop, store {
        coin_id: u64,
        fee_point: u8,
    }

    /// initialize when create
    /// change when withdraw, drop when close
    struct StreamInfo has drop, store {
        sender: address,
        recipient: address,
        rate_per_second: u64,
        start_time: u64,
        stop_time: u64,
        last_withdraw_time: u64,
        deposit_amount: u64, // no update

        remaining_balance: u64, // update when withdraw
        // sender_balance: u64,    // update when per second
        // recipient_balance: u64, // update when per second

    }
    
    struct Escrow<phantom CoinType> has key {
        coin: Coin<CoinType>,
    }

    struct GlobalConfig has key {
        fee_recipient: address,
        admin: address,
        coin_configs: vector<CoinConfig>,
        stream_events: EventHandle<StreamEvent>,
        config_events: EventHandle<ConfigEvent>
    }

    struct CoinConfig has store {
        next_id: u64,
        fee_point: u8,
        coin_type: String,
        coin_id: u64,
        escrow_address: address,
        store: Table<u64, StreamInfo>,
    }
    
    /// A helper function that returns the address of CoinType.
    public fun coin_address<CoinType>(): address {
        let type_info = type_info::type_of<CoinType>();
        type_info::account_address(&type_info)
    }

    public fun check_operator(
        operator_address: address,
        require_admin: bool
    ) acquires GlobalConfig {
        assert!(
            exists<GlobalConfig>(@Stream), error::already_exists(STREAM_NOT_PUBLISHED),
        );
        assert!(
            !require_admin || admin() == operator_address || @Stream == operator_address, error::permission_denied(STREAM_PERMISSION_DENIED),
        );
    }

    /// set fee_recipient and admin
    public entry fun initialize(
        owner: &signer,
        fee_recipient: address,
        admin: address,
    ) {
        let owner_addr = signer::address_of(owner);
        assert!(
            @Stream == owner_addr,
            error::permission_denied(STREAM_PERMISSION_DENIED),
        );

        assert!(
            !exists<GlobalConfig>(@Stream), error::already_exists(STREAM_HAS_PUBLISHED),
        );

        move_to(owner, GlobalConfig {
                fee_recipient,
                admin,
                coin_configs: vector::empty<CoinConfig>(),
                stream_events: account::new_event_handle<StreamEvent>(owner),
                config_events: account::new_event_handle<ConfigEvent>(owner)
            }
        );
    }

    /// register a coin type for streampay and initialize it
    public entry fun register_coin<CoinType>(
        admin: &signer
    ) acquires GlobalConfig {
        let admin_addr = signer::address_of(admin);
        check_operator(admin_addr, true);

        let coin_type = type_info::type_name<CoinType>();

        // escrow address 
        let (resource, _signer_cap) = account::create_resource_account(admin, *string::bytes(&coin_type));

        assert!(
            !exists<Escrow<CoinType>>(signer::address_of(&resource)), STREAM_HAS_REGISTERED
        );

        move_to(
            &resource, 
            Escrow<CoinType> { 
                coin: coin::zero<CoinType>() 
            }
        );

        let global = borrow_global_mut<GlobalConfig>(@Stream);
        let next_coin_id = vector::length(&global.coin_configs);
        
        let _new_coin_config = CoinConfig {
            next_id: 1,
            fee_point: INIT_FEE_POINT,
            coin_type,
            coin_id: next_coin_id,
            escrow_address: signer::address_of(&resource),
            store: table::new<u64, StreamInfo>(),
        };

        vector::push_back(&mut global.coin_configs, _new_coin_config)
    }

    /// create a stream
    public entry fun create<CoinType>(
        sender: &signer,
        recipient: address,
        deposit_amount: u64, // ex: 100,0000
        start_time: u64,
        stop_time: u64,
        coin_id: u64,
    ) acquires GlobalConfig, Escrow {
        // 1. check args

        let sender_address = signer::address_of(sender);
        check_operator(sender_address, false);

        assert!(
            deposit_amount >= MIN_DEPOSIT_BALANCE, error::invalid_argument(STREAM_BALANCE_TOO_LITTLE)
        );

        assert!(
            coin::balance<CoinType>(sender_address) >= deposit_amount, error::invalid_argument(STREAM_INSUFFICIENT_BALANCES)
        );

        // 2. get _config

        let global = borrow_global_mut<GlobalConfig>(@Stream);
        let _config = vector::borrow_mut(&mut global.coin_configs, coin_id);
        
        assert!(
            _config.coin_type == type_info::type_name<CoinType>(), error::invalid_argument(STREAM_COIN_TYPE_MISMATCH)
        );
        
        let duration = stop_time - start_time;
        let rate_per_second: u64 = deposit_amount / duration;

        let _stream_id = _config.next_id;
        let stream = StreamInfo {
            remaining_balance: 0u64,
            // sender_balance: deposit_amount,
            // recipient_balance: deposit_amount,
            
            sender: sender_address,
            recipient,
            rate_per_second: rate_per_second,
            start_time,
            stop_time,
            last_withdraw_time: start_time,
            deposit_amount,
        };

        // 3. handle assets

        // fee
        // let (fee_num, to_escrow) = calculate_fee(deposit_amount, _config.fee_point); // 2.5 % ---> fee = 250, 2500, 25000, to_escrow = 100,0000 - 2,5000 --> 97,5000
        // let fee_coin = coin::withdraw<CoinType>(sender, fee_num); // 25000
        // coin::deposit<CoinType>(global.fee_recipient, fee_coin); // 21000 or 25000

        // to escrow
        let to_escrow_coin = coin::withdraw<CoinType>(sender, deposit_amount); // 97,5000
        stream.remaining_balance = coin::value(&to_escrow_coin);
        merge_coin<CoinType>(_config.escrow_address, to_escrow_coin); 

        // 4. store stream

        table::add(&mut _config.store, _stream_id, stream);

        // 5. update next_id

        _config.next_id = _stream_id + 1;

        // 6. emit create event

        event::emit_event<StreamEvent>(
            &mut global.stream_events,
            StreamEvent {
                id: _stream_id,
                coin_id: _config.coin_id,
                event_type: EVENT_TYPE_CREATE,
                remaining_balance: deposit_amount
            },
        );
    }

    public entry fun close<CoinType>(
        sender: &signer,
        coin_id: u64,
        stream_id: u64,
    ) acquires GlobalConfig, Escrow {
        // 1. check args

        let sender_address = signer::address_of(sender);
        //create can not be called by admin?
        check_operator(sender_address, false);

        // 2. get _config
        let global = borrow_global_mut<GlobalConfig>(@Stream);
        let _config = vector::borrow_mut(&mut global.coin_configs, coin_id);
        assert!(
            table::contains(&_config.store, stream_id), error::not_found(STREAM_NOT_FOUND),
        );
        assert!(
            _config.coin_type == type_info::type_name<CoinType>(), error::invalid_argument(STREAM_COIN_TYPE_MISMATCH)
        );

        // 3. check stream stats

        let stream = table::borrow_mut(&mut _config.store, stream_id);
        assert!(stream.sender == sender_address, error::invalid_argument(STREAM_PERMISSION_DENIED));

        let escrow_coin = borrow_global_mut<Escrow<CoinType>>(_config.escrow_address);

        assert!(
            stream.remaining_balance <= coin::value(&escrow_coin.coin),
            error::invalid_argument(STREAM_INSUFFICIENT_BALANCES),
        );

        // 4. handle assets

        coin::deposit(sender_address, coin::extract(&mut escrow_coin.coin, stream.remaining_balance));

        // 5. update stream stats

        stream.remaining_balance = 0;

        // 6. emit open event

        event::emit_event<StreamEvent>(
            &mut global.stream_events,
            StreamEvent {
                id: stream_id,
                coin_id: _config.coin_id,
                event_type: EVENT_TYPE_CLOSE,
                remaining_balance: coin::value(&escrow_coin.coin)
            },
        );
    }

    fun merge_coin<CoinType>(
        resource: address,
        coin: Coin<CoinType>
    ) acquires Escrow {
        let escrow = borrow_global_mut<Escrow<CoinType>>(resource);
        coin::merge(&mut escrow.coin, coin);
    }

    public entry fun withdraw<CoinType>(
        operator: &signer,
        coin_id: u64,
        stream_id: u64,
    ) acquires GlobalConfig, Escrow {
        let current_time = timestamp::now_seconds();
        withdraw_internal<CoinType>(operator, coin_id, stream_id, current_time);
    }

    /// id: stream id
    fun withdraw_internal<CoinType>(
        operator: &signer,
        coin_id: u64,
        stream_id: u64,
        current_time: u64,
    ) acquires GlobalConfig, Escrow {
        // 1. check args
        let operator_address = signer::address_of(operator);
        check_operator(operator_address, false);

        // 2. get handler

        let global = borrow_global_mut<GlobalConfig>(@Stream);
        let _config = vector::borrow_mut(&mut global.coin_configs, coin_id);
        assert!(
            table::contains(&_config.store, stream_id), error::not_found(STREAM_NOT_FOUND),
        );
        assert!(
            _config.coin_type == type_info::type_name<CoinType>(), error::invalid_argument(STREAM_COIN_TYPE_MISMATCH)
        );

        // 3. check stream stats

        let stream = table::borrow_mut(&mut _config.store, stream_id);
        let escrow_coin = borrow_global_mut<Escrow<CoinType>>(_config.escrow_address);
        

        let (delta, last_withdraw_time) = delta_of(stream.last_withdraw_time, stream.stop_time, current_time);
        let withdraw_amount = stream.rate_per_second * delta;

        assert!(
            withdraw_amount <= stream.remaining_balance && withdraw_amount <= coin::value(&escrow_coin.coin),
            error::invalid_argument(STREAM_INSUFFICIENT_BALANCES),
        );

        // 4. handle assets

        // fee
        let (fee_num, to_recipient) = calculate_fee(withdraw_amount, _config.fee_point); // 2.5 % ---> fee = 250, 2500, 25000, to_escrow = 100,0000 - 2,5000 --> 97,5000
        coin::deposit<CoinType>(global.fee_recipient, coin::extract(&mut escrow_coin.coin, fee_num));

        //withdraw amount
        coin::deposit<CoinType>(stream.recipient, coin::extract(&mut escrow_coin.coin, to_recipient));

        // 5. update stream stats

        stream.remaining_balance = stream.remaining_balance - withdraw_amount;
        stream.last_withdraw_time = last_withdraw_time;

        // 6. emit open event

        event::emit_event<StreamEvent>(
            &mut global.stream_events,
            StreamEvent {
                id: stream_id,
                coin_id: _config.coin_id,
                event_type: EVENT_TYPE_WITHDRAW,
                remaining_balance: coin::value(&escrow_coin.coin)
            },
        );
    }

    /// call by  owner
    /// set new fee point
    public entry fun set_fee_point(
        owner: &signer,
        coin_id: u64,
        new_fee_point: u8,
    ) acquires GlobalConfig {
        let operator_address = signer::address_of(owner);
        assert!(
            @Stream == operator_address, error::invalid_argument(STREAM_PERMISSION_DENIED),
        );

        let global = borrow_global_mut<GlobalConfig>(@Stream);
        let _config = vector::borrow_mut(&mut global.coin_configs, coin_id);

        _config.fee_point = new_fee_point;

        event::emit_event<ConfigEvent>(
            &mut global.config_events,
            ConfigEvent {
                coin_id: _config.coin_id,
                fee_point: _config.fee_point
            },
        );
    }

    public fun calculate_fee(
        deposit_amount: u64,
        fee_point: u8,
    ): (u64, u64) {
        let fee = deposit_amount * (fee_point as u64) / 10000;

        // never overflow
        (fee, deposit_amount - fee)
    }

    public fun escrow_balance<CoinType>(coin_id: u64): u64 
        acquires GlobalConfig 
    {
        assert!(
            exists<GlobalConfig>(@Stream), error::already_exists(STREAM_NOT_PUBLISHED),
        );

        let global = borrow_global<GlobalConfig>(@Stream);
        let _config = vector::borrow(&global.coin_configs, coin_id);

        let escrow_balance = coin::balance<CoinType>(_config.escrow_address);

        return escrow_balance
    }

    // remaining_balance =  deposit_amount - withdrawed amount
    public fun remaining_balance<CoinType>(coin_id: u64, stream_id: u64): u64 
        acquires GlobalConfig 
    {
        let global = borrow_global<GlobalConfig>(@Stream);
        let _config = vector::borrow(&global.coin_configs, coin_id);
        let stream = table::borrow(&_config.store, stream_id);
        let remaining_balance = stream.remaining_balance;       // total remaining amount
        remaining_balance
    }

    // sender balance = rate_per_second * (duration - delta)
    public fun sender_balance<CoinType>(coin_id: u64, stream_id: u64): u64 
        acquires GlobalConfig 
    {

        let current_time = timestamp::now_seconds();
        let global = borrow_global<GlobalConfig>(@Stream);
        let _config = vector::borrow(&global.coin_configs, coin_id);

        let stream = table::borrow(&_config.store, stream_id);

        let (delta, _) = delta_of(stream.start_time, stream.stop_time, current_time); // total
        
        let sender_balance = (stream.start_time - stream.stop_time - delta) * stream.rate_per_second;

        sender_balance
    }

    // recipient balance = rate_per_second * (duration - delta)
    public fun recipient_balance<CoinType>(coin_id: u64, stream_id: u64): u64 
        acquires GlobalConfig
    {
        let current_time = timestamp::now_seconds();
        let global = borrow_global<GlobalConfig>(@Stream);
        let _config = vector::borrow(&global.coin_configs, coin_id);

        let stream = table::borrow(&_config.store, stream_id);

        let withdrawed_amount = stream.deposit_amount - stream.remaining_balance;

        let (delta, _) = delta_of(stream.start_time, stream.stop_time, current_time); // total
        
        let transfered_amount = delta * stream.rate_per_second;

        let recipient_balance = transfered_amount - withdrawed_amount;

        recipient_balance

    }

    public fun delta_of(last_withdraw_time: u64, stop_time: u64, current_time: u64) : (u64, u64) {
        let delta = stop_time - last_withdraw_time;

        if(current_time < last_withdraw_time){
            return (0u64, current_time)
        };

        if(current_time < stop_time){
            return (current_time - last_withdraw_time, current_time)
        };

        (delta, stop_time)
    }

    // public views for global config start 
    public fun fee_recipient(): address acquires GlobalConfig {
        borrow_global<GlobalConfig>(@Stream).fee_recipient
    }

    public fun admin(): address acquires GlobalConfig {
        borrow_global<GlobalConfig>(@Stream).admin
    }

    public fun fee_point(coin_id: u64): u8 acquires GlobalConfig {
        let global = borrow_global<GlobalConfig>(@Stream);
        vector::borrow(&global.coin_configs, coin_id).fee_point
    }

    public fun next_id(coin_id: u64): u64 acquires GlobalConfig {
        let global = borrow_global<GlobalConfig>(@Stream);
        vector::borrow(&global.coin_configs, coin_id).next_id
    }

    public fun coin_type(index: u64): String acquires GlobalConfig {
        let global = borrow_global<GlobalConfig>(@Stream);
        vector::borrow(&global.coin_configs, index).coin_type
    }

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use aptos_std::debug;

    #[test_only]
    struct FakeMoney {}

    #[test_only]
    public entry fun withdraw_test<CoinType>(
        operator: &signer,
        coin_id: u64,
        stream_id: u64,
        current_time: u64,
    ) acquires GlobalConfig, Escrow {
        withdraw_internal<CoinType>(operator, coin_id, stream_id, current_time);
    }

    #[test(account = @0x1, stream= @Stream, admin = @Admin)]
    fun test(account: signer, stream: signer, admin: signer) acquires GlobalConfig, Escrow {

        let stream_addr = signer::address_of(&stream);
        account::create_account_for_test(stream_addr);
        let admin_addr = signer::address_of(&admin);
        account::create_account_for_test(admin_addr);
        let account_addr = signer::address_of(&account);
        account::create_account_for_test(account_addr);

        let name = b"Fake money";
        let symbol = b"FMD";

        managed_coin::initialize<FakeMoney>(&stream, name, symbol, 8, false);
        managed_coin::register<FakeMoney>(&account);
        managed_coin::register<FakeMoney>(&admin);
        managed_coin::register<FakeMoney>(&stream);
        managed_coin::mint<FakeMoney>(&stream, admin_addr, 100000);
        assert!(coin::balance<FakeMoney>(admin_addr) == 100000, 0);

        //initialize
        assert!(
            !exists<GlobalConfig>(@Stream), 1,
        );
        let recipient = stream_addr;
        initialize(&stream, recipient, admin_addr);
        assert!(exists<GlobalConfig>(@Stream), 2);

        //register
        register_coin<FakeMoney>(&admin);
        assert!(!exists<Escrow<FakeMoney>>(admin_addr), 3);
        assert!(coin_type(0) == type_info::type_name<FakeMoney>(), 4);
        assert!(next_id(0) == 1, 5);
        assert!(fee_point(0) == INIT_FEE_POINT, 5);

        //create
        create<FakeMoney>(&admin, recipient, 60000, 10000, 10005, 0);
        assert!(coin::balance<FakeMoney>(admin_addr) == 40000, 0);
        // get _config
        let global = borrow_global_mut<GlobalConfig>(@Stream);
        let _config = vector::borrow(&global.coin_configs, 0);

        assert!(_config.next_id == 2, 5);
        let _stream = table::borrow(&_config.store, 1);
        debug::print(&coin::balance<FakeMoney>(recipient));
        let escrow_coin = borrow_global<Escrow<FakeMoney>>(_config.escrow_address);
        debug::print(&coin::value(&escrow_coin.coin));
        assert!(_stream.recipient == recipient, 0);
        assert!(_stream.sender == admin_addr, 0);
        assert!(_stream.start_time == 10000, 0);
        assert!(_stream.stop_time == 10005, 0);
        assert!(_stream.deposit_amount == 60000, 0);
        assert!(_stream.remaining_balance == coin::value(&escrow_coin.coin), 0);
        assert!(_stream.rate_per_second == 60000/5, 0);
        assert!(_stream.last_withdraw_time == 10000, 0);

        //wthidraw
        let beforeWithdraw = coin::balance<FakeMoney>(recipient);
        debug::print(&coin::balance<FakeMoney>(recipient));

        withdraw_test<FakeMoney>(&stream, 0, 1, 10000);
        debug::print(&coin::balance<FakeMoney>(recipient));
        let global = borrow_global_mut<GlobalConfig>(@Stream);
        let _config = vector::borrow(&global.coin_configs, 0);
        let _stream = table::borrow(&_config.store, 1);
        assert!(_stream.last_withdraw_time == 10000, 0);
        assert!(coin::balance<FakeMoney>(recipient) == beforeWithdraw, 0);

        withdraw_test<FakeMoney>(&stream, 0, 1, 10001);
        debug::print(&coin::balance<FakeMoney>(recipient));
        let global = borrow_global_mut<GlobalConfig>(@Stream);
        let _config = vector::borrow(&global.coin_configs, 0);
        let _stream = table::borrow(&_config.store, 1);
        assert!(_stream.last_withdraw_time == 10001, 0);
        assert!(coin::balance<FakeMoney>(recipient) == beforeWithdraw + 60000/5 * 1, 0);

        withdraw_test<FakeMoney>(&stream, 0, 1, 10002);
        debug::print(&coin::balance<FakeMoney>(recipient));
        let global = borrow_global_mut<GlobalConfig>(@Stream);
        let _config = vector::borrow(&global.coin_configs, 0);
        let _stream = table::borrow(&_config.store, 1);
        assert!(_stream.last_withdraw_time == 10002, 0);
        assert!(coin::balance<FakeMoney>(recipient) == beforeWithdraw + 60000/5 * 2, 0);

        withdraw_test<FakeMoney>(&stream, 0, 1, 10003);
        debug::print(&coin::balance<FakeMoney>(recipient));
        let global = borrow_global_mut<GlobalConfig>(@Stream);
        let _config = vector::borrow(&global.coin_configs, 0);
        let _stream = table::borrow(&_config.store, 1);
        assert!(_stream.last_withdraw_time == 10003, 0);
        assert!(coin::balance<FakeMoney>(recipient) == beforeWithdraw + 60000/5 * 3, 0);

        withdraw_test<FakeMoney>(&stream, 0, 1, 10004);
        debug::print(&coin::balance<FakeMoney>(recipient));
        let global = borrow_global_mut<GlobalConfig>(@Stream);
        let _config = vector::borrow(&global.coin_configs, 0);
        let _stream = table::borrow(&_config.store, 1);
        assert!(_stream.last_withdraw_time == 10004, 0);
        assert!(coin::balance<FakeMoney>(recipient) == beforeWithdraw + 60000/5 * 4, 0);

        withdraw_test<FakeMoney>(&stream, 0, 1, 10005);
        debug::print(&coin::balance<FakeMoney>(recipient));
        let global = borrow_global_mut<GlobalConfig>(@Stream);
        let _config = vector::borrow(&global.coin_configs, 0);
        let _stream = table::borrow(&_config.store, 1);
        assert!(_stream.last_withdraw_time == 10005, 0);
        assert!(coin::balance<FakeMoney>(recipient) == beforeWithdraw + 60000/5 * 5, 0);

        withdraw_test<FakeMoney>(&stream, 0, 1, 10006);
        debug::print(&coin::balance<FakeMoney>(recipient));
        let global = borrow_global_mut<GlobalConfig>(@Stream);
        let _config = vector::borrow(&global.coin_configs, 0);
        let _stream = table::borrow(&_config.store, 1);
        assert!(_stream.last_withdraw_time == 10005, 0);
        assert!(coin::balance<FakeMoney>(recipient) == beforeWithdraw + 60000/5 * 5, 0);
    }

}
