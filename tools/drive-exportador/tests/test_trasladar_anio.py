import importlib.util
from pathlib import Path
import unittest

P = Path(__file__).parents[1] / 'trasladar_anio.py'
sp = importlib.util.spec_from_file_location('trasladar_anio', P)
mod = importlib.util.module_from_spec(sp)
sp.loader.exec_module(mod)

class TestMigracionSegura(unittest.TestCase):
    def test_nombres_y_carpetas(self):
        self.assertEqual(mod.year_of('2021 - Castillo/20211113_141319.mp4'), 2021)
        self.assertEqual(mod.year_of('2021 - Castillo/VID-20200728-WA0016.mp4'), 2020)
        self.assertEqual(mod.year_of('Videos/2024-10/video.mov'), 2024)
        self.assertIsNone(mod.year_of('Videos/indeterminado.mp4'))
        self.assertIsNone(mod.year_of('2020_2023_duplicado.mp4'))
    def test_year_auto_and_limit(self):
        a=[{'path':'20210101.mp4','size':500,'md5':'a'*32,'year':2021},
           {'path':'20220101.mp4','size':300,'md5':'b'*32,'year':2022}]
        year, selected, totals = mod.select_year(a, 'auto', 600)
        self.assertEqual((year,len(selected),totals[2021]), (2021,1,500))
        with self.assertRaises(ValueError):
            mod.select_year(a,'2021',500)
    def test_reuse_previous_copy(self):
        x={'path':'2021 - Castillo/20211113_141319.mp4','size':10,'md5':'e'*32}
        dest={'20211113_141319.mp4': {'Size':10,'Hashes':{'MD5':'e'*32}}}
        self.assertEqual(mod.target_name(x,dest,__import__('collections').Counter({'20211113_141319.mp4':1})), '20211113_141319.mp4')
    def test_missing_hash_forbids_deletion(self):
        a=[{'path':'20210101.mp4','size':5,'md5':'','year':2021}]
        with self.assertRaises(ValueError): mod.select_year(a,'2021',999)

if __name__ == '__main__': unittest.main()
