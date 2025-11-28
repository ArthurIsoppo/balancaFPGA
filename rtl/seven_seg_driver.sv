`timescale 1ns / 1ps

//Módulo Driver para Display de 7 Segmentos e 8 Dígitos (Common Anode)
//  Este módulo recebe um número binário de 24 bits e o exibe como um
//número decimal de 8 dígitos nos displays de 7 segmentos da Nexys A7.

module seven_seg_driver (
    input logic clock,
    input logic reset,
    input logic [23:0] binary_in,

    output logic [7:0] segments_out, // Para os pinos DDP[7:0]
    output logic [7:0] anodes_out     // Para os pinos AN[7:0]
);

    // --- 1. Geração do Clock de Refresh ---

    logic [15:0] refresh_counter;
    logic refresh_tick;

    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            refresh_counter <= '0;
            refresh_tick <= 1'b0;
        end else begin
            refresh_tick <= 1'b0; // O tick dura apenas um ciclo
            if (refresh_counter == 16'd65535) begin
                refresh_counter <= '0;
                refresh_tick <= 1'b1;
            end else begin
                refresh_counter <= refresh_counter + 1;
            end
        end
    end

    // --- 2. Conversão Binário para BCD (Double Dabble) ---
    
    logic [31:0] bcd_digits; // 8 dígitos x 4 bits/dígito

    always_comb begin
        logic [23:0] bin_copy;
        logic [31:0] bcd_temp;
        
        bin_copy = binary_in;
        bcd_temp = '0;

        // Repete 24 vezes (uma para cada bit de entrada)
        for (int i = 0; i < 24; i++) begin
            for (int j = 0; j < 8; j++) begin
                if (bcd_temp[ (j*4) +: 4 ] > 4) begin
                bcd_temp[ (j*4) +: 4 ] = bcd_temp[ (j*4) +: 4 ] + 3;
                end
            end
            // O bit mais alto do binário entra no BCD
            {bcd_temp, bin_copy} = {bcd_temp, bin_copy} << 1;
        end
        
        bcd_digits = bcd_temp; // O resultado final
    end


    // --- 3. Multiplexação e Decodificação ---
    
    logic [2:0] digit_selector; // Contador para selecionar o dígito (0 a 7)
    logic [3:0] current_bcd_digit; // O dígito BCD a ser exibido agora
    
    // O contador de dígitos só avança no "refresh_tick"
    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            digit_selector <= '0;
        end else if (refresh_tick) begin
            digit_selector <= digit_selector + 1; // Avança (7 -> 0)
        end
    end

    // Seleciona qual dos 8 dígitos BCD será exibido
    // Este é um multiplexador de 8 para 1
    always_comb begin
        case (digit_selector)
            3'd0:    current_bcd_digit = bcd_digits[3:0];   // Dígito 0 (1s)
            3'd1:    current_bcd_digit = bcd_digits[7:4];   // Dígito 1 (10s)
            3'd2:    current_bcd_digit = bcd_digits[11:8];  // Dígito 2 (100s)
            3'd3:    current_bcd_digit = bcd_digits[15:12]; // Dígito 3 (1,000s)
            3'd4:    current_bcd_digit = bcd_digits[19:16]; // Dígito 4 (10,000s)
            3'd5:    current_bcd_digit = bcd_digits[23:20]; // Dígito 5 (100,000s)
            3'd6:    current_bcd_digit = bcd_digits[27:24]; // Dígito 6 (1,000,000s)
            3'd7:    current_bcd_digit = bcd_digits[31:28]; // Dígito 7 (10,000,000s)
            default: current_bcd_digit = 4'b1111;         // Padrão (blank)
        endcase
    end

    // Decodificador BCD para 7 Segmentos (Common Anode -> 0 = ON)
    // O padrão de bits corresponde a DDP[7:0] = (ca, cb, cc, cd, ce, cf, cg, dp)
    // O decimal point (dp, DDP[0]) está sempre desligado (1)
    always_comb begin
        case (current_bcd_digit)
            4'd0:    segments_out = 8'b00000011; // "0"
            4'd1:    segments_out = 8'b10011111; // "1"
            4'd2:    segments_out = 8'b00100101; // "2"
            4'd3:    segments_out = 8'b00001101; // "3"
            4'd4:    segments_out = 8'b10011001; // "4"
            4'd5:    segments_out = 8'b01001001; // "5"
            4'd6:    segments_out = 8'b01000001; // "6"
            4'd7:    segments_out = 8'b00011111; // "7"
            4'd8:    segments_out = 8'b00000001; // "8"
            4'd9:    segments_out = 8'b00001001; // "9"
            default: segments_out = 8'b11111111; // Off (blank)
        endcase
    end

    // Controlador dos Anodos (Ativo-Baixo)
    // Acende apenas o dígito selecionado (coloca em '0')
    always_comb begin
        case (digit_selector)
            3'd0:    anodes_out = 8'b11111110; // AN[0] ON
            3'd1:    anodes_out = 8'b11111101; // AN[1] ON
            3'd2:    anodes_out = 8'b11111011; // AN[2] ON
            3'd3:    anodes_out = 8'b11110111; // AN[3] ON
            3'd4:    anodes_out = 8'b11101111; // AN[4] ON
            3'd5:    anodes_out = 8'b11011111; // AN[5] ON
            3'd6:    anodes_out = 8'b10111111; // AN[6] ON
            3'd7:    anodes_out = 8'b01111111; // AN[7] ON
            default: anodes_out = 8'b11111111; // All OFF
        endcase
    end

endmodule