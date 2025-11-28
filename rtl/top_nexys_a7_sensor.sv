module top_nexys_a7 (
    input logic clock,      // 100MHz
    input logic reset,
    
    input logic hx711_data_in,
    output logic hx711_sclk_out,

    output logic [5:0] states_led,
    output logic [7:0] DDP,
    output logic [7:0] AN
);

    // =========================================================================
    // 1. Geração de Clocks e Reset
    // =========================================================================
    logic clock50MHz;
    always_ff @(posedge clock, posedge reset) begin
        if (reset) clock50MHz <= 0;
        else       clock50MHz <= ~clock50MHz;
    end

    // =========================================================================
    // 2. Driver HX711 (Sincronizado)
    // =========================================================================
    logic hx711_data_sync1, hx711_data_sync2;
    always_ff @(posedge clock50MHz) begin
        hx711_data_sync1 <= hx711_data_in;
        hx711_data_sync2 <= hx711_data_sync1; 
    end

    logic [23:0] s_hx711_raw_bits; 
    logic        s_hx711_tick;     
    
    hx711driver inst_hx711_driver (
        .clk(clock50MHz), 
        .reset(reset), 
        .dvsr(16'd50), 
        .start(1'b1), 
        .dout(s_hx711_raw_bits), 
        .hx711_done_tick(s_hx711_tick),
        .ready(), 
        .sclk(hx711_sclk_out), 
        .hx711_in(hx711_data_sync2) 
    );

    // =========================================================================
    // 3. Captura de Dados
    // =========================================================================
    logic signed [31:0] data_signed;
    assign data_signed = {{8{s_hx711_raw_bits[23]}}, s_hx711_raw_bits};

    // Detector de Borda do Tick
    logic s_tick_sync_r, s_tick_rising;
    always_ff @(posedge clock) s_tick_sync_r <= s_hx711_tick;
    assign s_tick_rising = s_hx711_tick && !s_tick_sync_r; 

    // =========================================================================
    // 4. Máquina de Estados Principal (Pipelined)
    // =========================================================================
    
    localparam int CLOCKS_PER_SECOND = 100_000_000;
    localparam int THRESHOLD = 50;                     //Valor que faz acender
    localparam int NOISE_LIMIT = 15000; 

    // --- Registradores de Processamento ---
    int timer_1sec;
    logic signed [63:0] accumulator_sum; 
    int sample_count;
    int consecutive_outliers;

    // Registradores de Média e Pipeline
    logic signed [31:0] current_second_avg;
    logic signed [31:0] previous_second_avg;
    logic signed [31:0] display_stable_val;
    logic signed [31:0] r_sample_captured; // Guarda a amostra para processar

    // --- Definição da FSM Estendida ---
    typedef enum logic [3:0] {
        ST_IDLE,         // 0: Espera tick ou timer
        
        // Pipeline de Processamento da Amostra
        ST_SAMPLE_CALC,  // 1: Calcula diferença
        ST_SAMPLE_CHECK, // 2: Verifica filtro de ruído
        ST_SAMPLE_ACCUM, // 3: Soma no acumulador

        // Pipeline de Divisão
        ST_PREP_DIV,     // 4
        ST_DIVIDE,       // 5
        ST_UPDATE,       // 6
        ST_CLEANUP       // 7
    } state_t;

    state_t state;

    // Vars da Divisão
    logic [63:0] div_dividend;
    logic [63:0] div_remainder;
    logic [31:0] div_divisor;
    logic [31:0] div_quotient;
    logic [6:0]  div_counter;
    logic        div_sign_bit;

    // Vars temporárias do Pipeline
    logic signed [31:0] r_diff;
    logic [31:0] r_abs_diff;
    logic        r_is_valid_sample;

    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            timer_1sec <= '0;
            accumulator_sum <= '0;
            sample_count <= '0;
            current_second_avg <= '0;
            previous_second_avg <= '0;
            display_stable_val <= '0;
            states_led <= '0;
            state <= ST_IDLE;
            
            div_dividend <= 0; 
            div_remainder <= 0; 
            div_divisor <= 0;
            div_quotient <= 0; 
            div_counter <= 0; 
            div_sign_bit <= 0;
            consecutive_outliers <= 0;
            
            r_sample_captured <= 0;
            r_diff <= 0;
            r_abs_diff <= 0;
            r_is_valid_sample <= 0;
        end
        else begin
            case (state)
                // ---------------------------------------------------------
                // 1. IDLE: Monitora eventos
                // ---------------------------------------------------------
                ST_IDLE: begin
                    // Prioridade 1: Chegou dado novo?
                    if (s_tick_rising) begin
                        r_sample_captured <= data_signed; // Captura para processar
                        state <= ST_SAMPLE_CALC;          // Vai processar
                    end 
                    // Prioridade 2: Deu 1 segundo?
                    else if (timer_1sec == CLOCKS_PER_SECOND - 1) begin
                        timer_1sec <= 0;
                        state <= ST_PREP_DIV;
                    end 
                    // Nada acontece, só conta tempo
                    else begin
                        timer_1sec <= timer_1sec + 1;
                    end
                end

                // ---------------------------------------------------------
                // PIPELINE DE AMOSTRA
                // ---------------------------------------------------------
                
                // Passo 1: Calcular Diferença
                ST_SAMPLE_CALC: begin
                    if (timer_1sec != CLOCKS_PER_SECOND - 1) timer_1sec <= timer_1sec + 1;

                    r_diff <= r_sample_captured - current_second_avg;
                    state <= ST_SAMPLE_CHECK;
                end

                // Passo 2: Calcular Absoluto e Decidir (Isolado da soma)
                ST_SAMPLE_CHECK: begin
                    if (timer_1sec != CLOCKS_PER_SECOND - 1) timer_1sec <= timer_1sec + 1;

                    // Lógica do valor absoluto
                    if (r_diff < 0) r_abs_diff <= unsigned'(-r_diff);
                    else            r_abs_diff <= unsigned'(r_diff);

                    state <= ST_SAMPLE_ACCUM;
                end

                // Passo 3: Acumular
                ST_SAMPLE_ACCUM: begin
                    if (timer_1sec != CLOCKS_PER_SECOND - 1) timer_1sec <= timer_1sec + 1;

                    // Verifica o filtro usando o valor calculado no passo anterior
                    if (r_abs_diff < NOISE_LIMIT || current_second_avg == 0 || consecutive_outliers >= 3) begin
                        accumulator_sum <= accumulator_sum + r_sample_captured;
                        sample_count <= sample_count + 1;
                        consecutive_outliers <= 0;
                    end else begin
                        consecutive_outliers <= consecutive_outliers + 1;
                    end

                    state <= ST_IDLE; // Volta a esperar
                end

                // ---------------------------------------------------------
                // PIPELINE DE DIVISÃO
                // ---------------------------------------------------------
                ST_PREP_DIV: begin
                    if (sample_count == 0) begin
                        current_second_avg <= 0;
                        state <= ST_UPDATE;
                    end else begin
                        if (accumulator_sum < 0) begin
                            div_dividend <= unsigned'(-accumulator_sum);
                            div_sign_bit <= 1'b1;
                        end else begin
                            div_dividend <= unsigned'(accumulator_sum);
                            div_sign_bit <= 1'b0;
                        end
                        div_divisor   <= unsigned'(sample_count);
                        div_remainder <= 0;
                        div_quotient  <= 0;
                        div_counter   <= 63; 
                        state <= ST_DIVIDE;
                    end
                end

                ST_DIVIDE: begin
                    div_remainder = (div_remainder << 1) | (div_dividend[div_counter]);
                    if (div_remainder >= div_divisor) begin
                        div_remainder = div_remainder - div_divisor;
                        div_quotient[div_counter] = 1'b1; 
                    end
                    if (div_counter == 0) state <= ST_UPDATE;
                    else div_counter <= div_counter - 1;
                end

                ST_UPDATE: begin
                    logic signed [31:0] temp_avg;
                    if (div_sign_bit) temp_avg = signed'(-div_quotient);
                    else              temp_avg = signed'(div_quotient);

                    current_second_avg <= temp_avg;
                    display_stable_val <= temp_avg;

                    if ((previous_second_avg - temp_avg) > THRESHOLD) states_led <= 6'b101101; 
                    else states_led <= 6'b000000;
                    
                    state <= ST_CLEANUP;
                end

                ST_CLEANUP: begin
                    previous_second_avg <= current_second_avg;
                    accumulator_sum <= 0;
                    sample_count <= 0;
                    state <= ST_IDLE; 
                end
                
                default: state <= ST_IDLE;
            endcase
        end
    end

    // =========================================================================
    // 5. Display
    // =========================================================================
    logic [23:0] final_display_number;
    always_comb begin
        if (display_stable_val < 0) final_display_number = unsigned'(-display_stable_val);
        else                        final_display_number = unsigned'(display_stable_val);
    end

    seven_seg_driver inst_display (
        .clock(clock),                  
        .reset(reset),                
        .binary_in(final_display_number),   
        .segments_out(DDP),           
        .anodes_out(AN)               
    );

endmodule