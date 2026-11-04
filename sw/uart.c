/*============================================================================
 *  MyXTRV32 v0.2  UART TX driver (polled)
 *    0x0002_0000  write : TX byte
 *    0x0002_0004  read  : bit0 = busy
 *============================================================================*/
#include <stdint.h>

#define UART_BASE   0x00020000u
#define UART_DATA   (*(volatile uint32_t *)(UART_BASE + 0u))
#define UART_STATUS (*(volatile uint32_t *)(UART_BASE + 4u))

void uart_putc_raw(char c)
{
    while (UART_STATUS & 1u)
    {
        /* wait for the transmitter to drain */
    }
    UART_DATA = (uint32_t)(unsigned char)c;
}

/* hook used by the CoreMark ee_printf port */
void uart_send_char(char c)
{
    if (c == '\n')
    {
        uart_putc_raw('\r');
    }
    uart_putc_raw(c);
}
