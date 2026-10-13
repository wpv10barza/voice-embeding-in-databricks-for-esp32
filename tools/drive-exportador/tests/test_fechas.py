import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from exportador_cloud import fecha_nombre, inventario


class TestExportador(unittest.TestCase):
    def test_fechas_admitidas(self):
        self.assertEqual(str(fecha_nombre('VID-20251001-WA0008.mp4')), '2025-10-01')
        self.assertEqual(str(fecha_nombre('20231202_190028.mp4')), '2023-12-02')
        self.assertEqual(str(fecha_nombre('2024.02.29.mp4')), '2024-02-29')
        self.assertIsNone(fecha_nombre('20240230.mp4'))
        self.assertIsNone(fecha_nombre('20260430.mp4'))
        self.assertIsNone(fecha_nombre('video_final.mp4'))

    def test_inventario_filtra_destino(self):
        objetos = [{'Path': 'Videos_Unidos_2020_2025_7z/20241031.mp4', 'Size': 10},
                   {'Path': 'carpeta/VID-20241010-WA0001.mp4', 'Size': 20},
                   {'Path': 'carpeta/sin_fecha.mp4', 'Size': 30},
                   {'Path': 'otros/20251001.txt', 'Size': 40}]
        validos, invalidos = inventario(objetos, 'Videos_Unidos_2020_2025_7z')
        self.assertEqual(len(validos), 1)
        self.assertEqual(validos[0]['mes'], '2024-10')
        self.assertEqual(len(invalidos), 1)

if __name__ == '__main__':
    unittest.main()